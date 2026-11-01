//
//  TrafficSearchField.swift
//  ReqRes
//
//  Copyright © 2025 Andrey Teologov. All rights reserved.
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
//  The tokenized search field, ported from snipperapp 3's
//  `TokenizedSearchField`: a thin SwiftUI shell — the magnifier, the committed
//  chips and the ✕ button — around the APPKIT text field owned by
//  `TrafficSearchFieldModel`.
//
//  Two rules keep this view from disturbing the toolbar around it:
//  1. It never sizes itself. The toolbar item applies an exact width; a
//     `minWidth…maxWidth` here made snipperapp's item re-measure on the first
//     keystroke (the clear button appearing changed the fitting size) and
//     shove its neighbours.
//  2. Its content never changes the layout. The clear button's slot is
//     reserved whether or not it shows, the chip row is clipped rather than
//     allowed to push, and the row height is a constant.
//

import MCPKit
import SwiftUI
import Utils

struct TrafficSearchField: View {
    /// Observed for `hasInputText` and the chip selection only — keystrokes
    /// publish nothing through the toolbar item.
    @ObservedObject var model: TrafficSearchFieldModel
    /// The committed filter (chips). Publishes on commits only.
    @ObservedObject var search: TrafficSearchState

    /// The exact width the owner has given this view, used to divide the box
    /// between the chips and the text input so the caret never gets squeezed
    /// out.
    let availableWidth: CGFloat

    /// Measured natural width of the chip row: a ScrollView has no intrinsic
    /// width, so the scroller gets an explicit one — the content's measured
    /// width, capped at `tokenRowMaxWidth`.
    @State private var chipsContentWidth: CGFloat = 0

    /// Fixed chrome inside the box: horizontal padding (20) + the three HStack
    /// gaps (18) + the magnifier glyph (14) + the clear button (14).
    private static let chromeWidth: CGFloat = 66
    /// The text input never gets less than this, whatever the chips do.
    private static let minimumTextWidth: CGFloat = 44
    /// The content row's height is a CONSTANT so committing a chip (22pt)
    /// beside the 16pt text field cannot grow the box.
    private static let contentHeight: CGFloat = 22
    private static let verticalPadding: CGFloat = 5

    private var tokenRowMaxWidth: CGFloat {
        max(0, availableWidth - Self.chromeWidth - Self.minimumTextWidth)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))

            // Committed chips in a MEASURED-WIDTH scroller: chips lay out at
            // natural size, scroll when they outgrow their cap, and can
            // neither widen the item nor starve the caret's room.
            if !search.filter.tokens.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        chipRow
                    }
                    .frame(width: min(chipsContentWidth, tokenRowMaxWidth), height: Self.contentHeight)
                    .onChange(of: model.selectedTokenIndex) { _, index in
                        let tokens = search.filter.tokens
                        if let index, tokens.indices.contains(index) {
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo(tokens[index].id)
                            }
                        }
                    }
                    .onChange(of: search.filter.tokens.count) { _, _ in
                        if let last = search.filter.tokens.last {
                            proxy.scrollTo(last.id)
                        }
                    }
                }
            }

            // The model's one stable NSTextField. Everything keyboard-related
            // (debounce, suggestions, arrows, Return, the Escape chain) lives
            // on the model, AppKit-side.
            TrafficSearchFieldCoreView(model: model, availableWidth: availableWidth)
                .frame(minWidth: Self.minimumTextWidth, maxWidth: .infinity)
                // Without a priority the HStack SPLITS the spare width between
                // the chip container and the field, stranding the caret
                // mid-box. The field wins; chips stay at their natural size.
                .layoutPriority(1)

            // Clear button — OUTSIDE the clipped chip row, its slot ALWAYS
            // reserved, so it can neither be clipped away nor change the
            // layout when the first character arrives.
            Button {
                model.clearAll()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .opacity(hasContentToClear ? 1 : 0)
            .allowsHitTesting(hasContentToClear)
            .accessibilityHidden(!hasContentToClear)
            .help("Clear the search")
        }
        .frame(height: Self.contentHeight)
        .padding(.horizontal, 10)
        .padding(.vertical, Self.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(TrafficSearchFieldChromeModifier())
    }

    /// The chip row, with per-chip selection (click a chip to select it;
    /// ←/→/Backspace then act on it).
    private var chipRow: some View {
        HStack(spacing: 4) {
            ForEach(Array(search.filter.tokens.enumerated()), id: \.element.id) { index, token in
                TrafficSearchTokenChip(token: token, isSelected: model.selectedTokenIndex == index) {
                    model.removeToken(token)
                }
                .fixedSize()
                .id(token.id)
                .onTapGesture { model.selectToken(at: index) }
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            chipsContentWidth = width
        }
    }

    private var hasContentToClear: Bool {
        !search.filter.isEmpty || model.hasInputText
    }
}

/// On macOS 26 the toolbar item's own glass platter is the field's capsule
/// and the inner focus ring is suppressed; earlier systems draw a quaternary
/// pill.
private struct TrafficSearchFieldChromeModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.focusEffectDisabled()
        } else {
            content
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Chip

/// A committed token as a capsule chip.
///
/// The glyph is the kind's symbol — a globe for a host, a tag for a pid —
/// except where a real icon is more truthful: an `app:` chip that names an app
/// the session index knows shows that app's icon, `app:unknown` shows the
/// table's dashed placeholder, and a `pid:` chip whose process the index has
/// seen shows its app's icon and names it in the tooltip. A chip typed for
/// something never captured keeps the symbol; nothing is guessed from the text.
struct TrafficSearchTokenChip: View {
    let token: TrafficSearchToken
    /// Keyboard/click selection — stronger fill plus an accent ring, so the
    /// chip Backspace will delete is unmistakable.
    var isSelected = false
    let onRemove: () -> Void

    var body: some View {
        if let help = TrafficSearchProcessLookup.chipHelp(for: token) ?? TrafficSearchDestinationLookup.chipHelp(for: token) {
            chip.help(help)
        } else {
            chip
        }
    }

    private var chip: some View {
        HStack(spacing: 4) {
            TrafficSearchSuggestionIconView(
                icon: TrafficSearchProcessLookup.icon(for: token), imageSize: 12, symbolSize: 9
            )
            // A country chip is committed as its code and READS as its name
            // (destination-map UX spec §5.3): Utils owns no locale, so the
            // upgrade from "DE" to "Germany" happens here.
            Text(TrafficSearchDestinationLookup.chipTitle(for: token) ?? token.displayName)
                .font(.system(size: 10))
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.blue.opacity(isSelected ? 0.45 : 0.15))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5))
    }
}

/// How the field turns an app name or a pid into an icon: the index
/// `SessionState` maintains in the flush (through `TrafficSearchState`'s
/// lookups, so the probe can seed it), then `ProcessIconCache` — never
/// `NSWorkspace` directly, and never a guess. A name or pid the index does not
/// hold gets the kind's symbol.
@MainActor
enum TrafficSearchProcessLookup {
    /// The icon for an app the panel offers or a chip names. "Unknown" is the
    /// table's placeholder, not an app, and gets the same dashed glyph the
    /// table draws for it.
    static func icon(forApp name: String, state: TrafficSearchState = .shared) -> TrafficSearchSuggestion.Icon {
        if name.caseInsensitiveCompare(TrafficSearchAppMatch.unknown) == .orderedSame {
            return .symbol("questionmark.app.dashed")
        }
        if let identity = state.appLookup(name)?.identity {
            // A system service draws as its symbol everywhere — the column does
            // the same — never as a tinted image that differs by surface.
            if identity.isSystemService, let symbol = identity.systemServiceSymbol { return .symbol(symbol) }
            if let image = ProcessIconCache.shared.icon(for: identity) { return .image(image) }
        }
        return .symbol(TrafficSearchTokenKind.app.symbolName)
    }

    /// The icon for a committed chip.
    static func icon(for token: TrafficSearchToken, state: TrafficSearchState = .shared) -> TrafficSearchSuggestion.Icon {
        switch token {
        case .app(let name):
            return icon(forApp: name, state: state)
        case .pid(let pid):
            guard let app = state.appLookupByPid(pid) else { return .symbol(TrafficSearchTokenKind.pid.symbolName) }
            return icon(forApp: app, state: state)
        case .outcome(let value):
            // The outcome's own glyph — the one its rows carry.
            return .symbol(MCPSessionOutcome.parse(value).map(FailureRowCopy.symbolName) ?? token.kind.symbolName)
        case .grpc(let value):
            return .symbol(value == "OK" ? "checkmark.circle" : token.kind.symbolName)
        case .proto(let value):
            // The same glyph the Metrics tab's Protocol row draws.
            return .symbol(NetworkMetricsView.symbolName(SessionProtocol.parse(value)))
        case .host, .method, .status, .path, .country:
            return .symbol(token.kind.symbolName)
        }
    }

    /// A pid chip names its app on hover — `"claude · pid 9437"` — when the
    /// index knows the process. Other chips say what they show.
    static func chipHelp(for token: TrafficSearchToken, state: TrafficSearchState = .shared) -> String? {
        guard case .pid(let pid) = token, let app = state.appLookupByPid(pid) else { return nil }
        return "\(app) · pid \(pid)"
    }
}

/// How the field shows a destination (destination-map UX spec §5.3): the
/// `country:` chip's title and tooltip, and the panel row's glyph. Everything
/// comes from `CountryPresentation` (MCPKit) — the same names and flags the
/// Destinations window shows — so a chip and the row it was committed from
/// cannot disagree. `TrafficSearchProcessLookup`'s sibling: that one asks the
/// session index for an icon; this one needs no state at all.
enum TrafficSearchDestinationLookup {
    /// The localised name for a country chip; the class labels as Utils
    /// already spells them (`displayName`); nil for every other kind so the
    /// caller falls through to `token.displayName`.
    static func chipTitle(for token: TrafficSearchToken) -> String? {
        guard case .country(let value) = token else { return nil }
        guard let destination = TrafficDestination.parseToken(value) else { return token.displayName }
        return CountryPresentation.title(for: destination)
    }

    /// `"country:US — requests whose server address resolved to United States"`
    /// and the three class sentences; nil for every other kind.
    static func chipHelp(for token: TrafficSearchToken) -> String? {
        guard case .country(let value) = token, let destination = TrafficDestination.parseToken(value) else { return nil }
        let prefix = "\(TrafficSearchTokenKind.country.prefix)\(destination.token) — "
        switch destination {
        case .country(let code):
            return prefix + "requests whose server address resolved to \(CountryPresentation.name(for: code))"
        case .thisMac:
            return prefix + "requests to this Mac"
        case .localNetwork:
            return prefix + "requests to your local network"
        case .unknown:
            return prefix + "requests ReqRes could not place"
        }
    }

    /// A suggestion row's glyph: the country's flag as text, the `map` symbol
    /// for a country without one (XK, ZZ), and each class's own symbol.
    static func icon(forToken token: String) -> TrafficSearchSuggestion.Icon {
        guard let destination = TrafficDestination.parseToken(token) else {
            return .symbol(TrafficSearchTokenKind.country.symbolName)
        }
        if let symbol = CountryPresentation.symbolName(for: destination) {
            return .symbol(symbol)
        }
        let flag = CountryPresentation.flag(for: destination.isoCode ?? "")
        return flag.isEmpty ? .symbol(TrafficSearchTokenKind.country.symbolName) : .text(flag)
    }
}

// MARK: - Suggestions

/// One row of the suggestions panel. Selectable rows commit `kind` +
/// `commitValue` as a token on click or Return; an info row (`isSelectable ==
/// false`) is text the keyboard skips — the syntax hint under an empty field,
/// or the reason `app:` has nothing to offer.
struct TrafficSearchSuggestion: Identifiable {
    let id: String
    let kind: TrafficSearchTokenKind
    /// What the row shows: a host, an app's display name, a pid's digits, a
    /// country's name.
    let title: String
    /// What Return commits. The title, except for a destination row, which
    /// reads "Germany" and commits `DE` (destination-map UX spec §5.3) — the
    /// parser accepts codes, never names.
    let commitValue: String
    /// Secondary text at the trailing edge: "3 processes" beside an app, the
    /// app's name beside a pid, "88 requests" beside a destination.
    let detail: String?
    let icon: Icon
    let isSelectable: Bool

    enum Icon {
        case symbol(String)
        case image(NSImage)
        /// A glyph drawn as text — a country's flag. Never at chip size.
        case text(String)
    }

    /// A committable row. `commitValue` defaults to the title.
    init(kind: TrafficSearchTokenKind, title: String, commitValue: String? = nil, detail: String? = nil, icon: Icon) {
        self.id = "\(kind.rawValue):\(title.lowercased())"
        self.kind = kind
        self.title = title
        self.commitValue = commitValue ?? title
        self.detail = detail
        self.icon = icon
        self.isSelectable = true
    }

    /// A non-selectable line of 10pt secondary text. It carries a kind and a
    /// symbol because every row does; neither is drawn.
    static func info(id: String, kind: TrafficSearchTokenKind, text: String) -> TrafficSearchSuggestion {
        TrafficSearchSuggestion(id: id, kind: kind, title: text, detail: nil, icon: .symbol("info.circle"), isSelectable: false)
    }

    private init(id: String, kind: TrafficSearchTokenKind, title: String, detail: String?, icon: Icon, isSelectable: Bool) {
        self.id = id
        self.kind = kind
        self.title = title
        self.commitValue = title
        self.detail = detail
        self.icon = icon
        self.isSelectable = isSelectable
    }
}

/// A titled run of rows. An empty title draws no header (the hint row under
/// the empty field's Hosts and Apps).
struct TrafficSearchSuggestionGroup {
    let title: String
    let rows: [TrafficSearchSuggestion]

    /// The rows the keyboard can reach, in panel order. `selectedIndex` on the
    /// model and the highlight in the view both index THIS list — one rule, so
    /// ↓ from the last host lands on the first app and Return commits the row
    /// that is lit.
    static func selectableRows(in groups: [TrafficSearchSuggestionGroup]) -> [TrafficSearchSuggestion] {
        groups.flatMap(\.rows).filter(\.isSelectable)
    }
}

/// The dropdown's rows, grouped — Hosts, Apps, Processes — under one flat
/// keyboard index.
struct TrafficSearchSuggestionsView: View {
    let groups: [TrafficSearchSuggestionGroup]
    /// Index into `TrafficSearchSuggestionGroup.selectableRows(in: groups)`.
    let selectedIndex: Int
    let onSelect: (TrafficSearchSuggestion) -> Void

    var body: some View {
        let selectable = TrafficSearchSuggestionGroup.selectableRows(in: groups)
        let highlightedID = selectable.indices.contains(selectedIndex) ? selectable[selectedIndex].id : nil
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(groups.enumerated()), id: \.offset) { position, group in
                if !group.title.isEmpty {
                    Text(group.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, position == 0 ? 0 : 6)
                        .padding(.bottom, 4)
                }
                ForEach(group.rows) { row in
                    if row.isSelectable {
                        Button {
                            onSelect(row)
                        } label: {
                            rowLabel(row, isHighlighted: row.id == highlightedID)
                        }
                        .buttonStyle(.plain)
                    } else {
                        infoRow(row)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    }

    private func rowLabel(_ row: TrafficSearchSuggestion, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            TrafficSearchSuggestionIconView(icon: row.icon, imageSize: 14, symbolSize: 10)
                .frame(width: 16)
            // A pid is digits the eye compares column-wise; a host is a name
            // that keeps its ends when it must give something up.
            Text(row.title)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(row.kind == .host ? .middle : .tail)
            Spacer()
            if let detail = row.detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isHighlighted ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
    }

    /// Text only: no icon slot, no highlight, not a button.
    private func infoRow(_ row: TrafficSearchSuggestion) -> some View {
        Text(row.title)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }
}

/// A row's or a chip's leading glyph: a real app icon (from `ProcessIconCache`,
/// stored at 16 and drawn smaller here) or an SF Symbol in the secondary colour.
struct TrafficSearchSuggestionIconView: View {
    let icon: TrafficSearchSuggestion.Icon
    let imageSize: CGFloat
    let symbolSize: CGFloat

    var body: some View {
        switch icon {
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: imageSize, height: imageSize)
                .accessibilityHidden(true)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: symbolSize))
                .foregroundStyle(.secondary)
        case .text(let glyph):
            // A flag is a two-scalar emoji; a point or two under the image
            // size keeps its box the same height as an app icon in the row.
            Text(glyph)
                .font(.system(size: imageSize - 2))
                .accessibilityHidden(true)
        }
    }
}

#Preview("Suggestions") {
    TrafficSearchSuggestionsView(
        groups: [
            TrafficSearchSuggestionGroup(title: "Hosts", rows: [
                TrafficSearchSuggestion(kind: .host, title: "api.example.com", icon: .symbol("globe")),
                TrafficSearchSuggestion(kind: .host, title: "cdn.example.com", icon: .symbol("globe")),
            ]),
            TrafficSearchSuggestionGroup(title: "Apps", rows: [
                TrafficSearchSuggestion(kind: .app, title: "claude", detail: "2 processes", icon: .symbol("app")),
                TrafficSearchSuggestion(kind: .app, title: "Unknown", icon: .symbol("questionmark.app.dashed")),
            ]),
            TrafficSearchSuggestionGroup(title: "Destinations", rows: [
                TrafficSearchSuggestion(kind: .country, title: "Germany", commitValue: "DE", detail: "88 requests", icon: .text("🇩🇪")),
                TrafficSearchSuggestion(kind: .country, title: "This Mac", commitValue: "mac", detail: "412 requests", icon: .symbol("desktopcomputer")),
            ]),
            TrafficSearchSuggestionGroup(title: "", rows: [
                .info(id: "hint", kind: .host, text: "host: · app: · pid: · country: · method: · status: · path:"),
            ]),
        ],
        selectedIndex: 2
    ) { _ in }
    .frame(width: 260)
    .padding()
}
