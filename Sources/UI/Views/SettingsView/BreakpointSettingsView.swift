//
//  BreakpointSettingsView.swift
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
//  Roadmap item 18: where breakpoints are turned on and aimed.
//
//  Its own tab, next to Capture, for the same reason Capture got one: this is
//  a setting that changes what the ENGINE does to live traffic, and this one
//  does the most drastic version of it — a matching request STOPS, and the app
//  or browser that made it sits there waiting for a human. A page that is
//  spinning for no visible reason is the most expensive kind of confusion this
//  app can cause, so every piece of copy below exists to make the armed state
//  impossible to be in by accident: the list says how many rules are live, the
//  off state says plainly that nothing is ever held, and one button disarms
//  everything.
//
//  The matching rules are the CORE's (`BreakpointRule.matches`, read from
//  XReqResCore/TunnelServices/Breakpoints/BreakpointModels.swift) — exact host
//  or a leading `*.` covering subdomains but not the bare domain, an optional
//  case-insensitive path substring, and an optional method list. This view
//  rejects anything the core could never match instead of storing it: a rule
//  sitting in the list doing nothing is indistinguishable, to the user, from
//  the feature being broken. Why a rule is refused, and the note that says
//  so, are `BreakpointRuleEntry` / `BreakpointRuleForm` (Utils, tested).
//

import SwiftUI
import Utils
import XReqResCore

struct BreakpointSettingsView: View {
    /// The whole service seam, in one place: `rules`,
    /// `addRule(host:pathContains:methods:)`, `removeRule(id:)` and
    /// `setRuleEnabled(_:id:)`. `BreakpointService` owns persistence and the
    /// push to the extension; this view owns nothing but what the user sees,
    /// so a change to how rules are stored never reaches here and a change to
    /// the copy never reaches the service.
    @ObservedObject private var service = BreakpointService.shared

    /// The Add form's three fields and what Add last refused in them. The
    /// note under the form is DERIVED from that and the rules as they are
    /// now (the F13 class): it was stored text that only a Host edit or a
    /// later Add cleared, so it outlived an edit of the path or the methods,
    /// and the removal of the rule it was about. Any edit forgets the refusal.
    @State private var form = BreakpointRuleForm()

    /// The standing permission for agents to answer held requests. Absent
    /// means off — deliberately NOT registered with a default anywhere, unlike
    /// the bridge's own switch, because that one opens a redacted read surface
    /// and this one hands out live traffic.
    @AppStorage(MCPBreakpointAdapter.defaultsKey) private var agentDecisions = false

    /// Offered in the method menu. Not a restriction — the core compares
    /// uppercased strings against whatever the request used — just the five
    /// anyone actually aims a breakpoint at.
    private static let commonMethods = ["GET", "POST", "PUT", "PATCH", "DELETE"]

    private var armedCount: Int { service.rules.filter(\.rule.enabled).count }

    var body: some View {
        Form {
            Section("Breakpoints") {
                Text("A breakpoint holds a matching request before it reaches the server and asks you what to do with it: send it on as-is, send it on with changes, or fail it outright. It is how you catch one request in flight instead of watching it go past.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // The one thing a user otherwise learns by accident, in the
                // middle of doing something else: a held request is a stopped
                // app. Said here, in full, before they can arm anything.
                Text("While a request is held, whatever made it is waiting — a page stays blank, an app shows a spinner. Nobody answering is a valid outcome, so ReqRes gives up on its own after \(Int(BreakpointRegistry.decisionTimeout)) seconds and sends the request on unchanged.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Plain http:// is held too since core ef40bdf (C5 put it on
                // the HTTPS exchange engine); this used to be an orange
                // "HTTPS only" warning. What still is never held is a host on
                // the exclusion list, which ReqRes relays without reading.
                Text("Breakpoints hold HTTPS and plain http:// requests alike. A host on the Settings ▸ Capture exclusion list is never held — ReqRes passes those connections through without reading them.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                stateRow

            Section("Rules") {
                if service.rules.isEmpty {
                    Text("No breakpoints yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    // Identified by the item's own id, not by position: two
                    // rules CAN be identical in every field, and a row keyed on
                    // its index moves under the user's cursor when an earlier
                    // one is removed. The service gives each rule a stable id
                    // for exactly this.
                    ForEach(service.rules) { item in
                        ruleRow(item)
                    }
                }

                // `prompt:`, not the title: a grouped Form promotes a
                // TextField's title to the row's LABEL column, which puts the
                // example text on the left of the row and leaves the field
                // itself unlabelled (measured — same trap as Capture and MCP).
                // Editing any of the three fields forgets the refusal
                // (`BreakpointRuleForm`): a rejection that stays on screen
                // while the user is fixing what it complained about reads as
                // a second, still-unexplained failure.
                LabeledContent("Host") {
                    TextField("", text: $form.host, prompt: Text("api.example.com, localhost or *.example.com"))
                        .textFieldStyle(.roundedBorder)
                        // A Form's value column right-aligns typed text; a
                        // host typed from the right reads as a bug.
                        .multilineTextAlignment(.leading)
                        .onSubmit(add)
                }

                LabeledContent("Path contains") {
                    TextField("", text: $form.path, prompt: Text("optional — e.g. /orders"))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .onSubmit(add)
                }

                LabeledContent("Methods") {
                    HStack(spacing: 8) {
                        methodMenu
                        Spacer(minLength: 0)
                        Button("Add Breakpoint", action: add)
                            .disabled(!form.canSubmit)
                    }
                }

                // Re-checked against the rules as they are now: removing the
                // rule "already in the list" named takes the note away.
                if let note = form.note(existing: service.rules.map(\.spec)) {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            }

            // After the rules, not before them: it is a grant rather than a
            // preference, and it means nothing until a breakpoint above can
            // actually hold something.
            Section("Agents") {
                Toggle("Let agents answer held requests", isOn: $agentDecisions)
                    .toggleStyle(.switch)

                Text("Off by default. With it on, a connected agent can read a held request and resume, edit or abort it — the same three choices you have in the panel, and every one of them is written to Settings → MCP → Activity. Agents can never create a breakpoint; the rules above are yours.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // The honest reason this is a switch rather than the approval
                // sheet every other agent change goes through. Said here
                // because this is where the user decides.
                Text("This is the one agent change ReqRes does not ask about each time: a held request is released after \(Int(BreakpointRegistry.decisionTimeout)) seconds, and waiting for an approval could take longer than the request has. Turning this off is immediate — the next decision is refused and the request stays yours to answer.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("What this means") {
                VStack(alignment: .leading, spacing: 6) {
                    bullet("A breakpoint matches on the host, plus — if you fill them in — a piece of the path and a set of methods. Leave those empty and every request to that host is held, which on a busy host is a lot of requests.")
                    bullet("A wildcard covers subdomains only: *.example.com holds api.example.com, but not example.com itself.")
                    bullet("The path is matched as plain text anywhere in the URL, not as a pattern: /orders catches /v2/orders and /orders/42 alike. Wildcards and regular expressions belong to rules, not here.")
                    bullet("Each held request is shown on its own, and several can be held at once — they queue, and the \(Int(BreakpointRegistry.decisionTimeout))-second clock runs on each one separately.")
                    bullet("Turning a breakpoint off, or removing it, does not release a request it is already holding while another breakpoint is still armed. Answer it, or let it time out. With none left armed, everything held is released, unchanged.")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - State

    /// The armed/disarmed answer, always in the same place, so "is anything
    /// going to stop my traffic?" never requires reading the list and doing
    /// the arithmetic.
    @ViewBuilder
    private var stateRow: some View {
        if service.rules.isEmpty {
            Label("Nothing is held. Add a breakpoint below to stop a request while you decide what to do with it.",
                  systemImage: "checkmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if armedCount == 0 {
            Label("Every breakpoint is switched off, so nothing is held. Traffic flows normally.",
                  systemImage: "checkmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(alignment: .top, spacing: 8) {
                Label(armedCount == 1
                      ? "1 breakpoint is armed. The next request it matches will stop and wait for you."
                      : "\(armedCount) breakpoints are armed. The next request any of them matches will stop and wait for you.",
                      systemImage: "pause.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                // The way out, in the place the armed state is announced: if
                // traffic is stopping and it is not wanted, the fix should not
                // be a row-by-row hunt through the list.
                Button("Turn All Off", action: disarmAll)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Rows

    private func ruleRow(_ item: BreakpointRuleItem) -> some View {
        let rule = item.rule
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { service.setRuleEnabled($0, id: item.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel("Hold requests matching \(rule.host)")

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.host)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                Text(Self.summary(of: rule))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            // A disabled rule still reads as a rule, just visibly inert —
            // dimming is the cheapest way to make "armed" countable at a
            // glance without a second badge per row.
            .opacity(rule.enabled ? 1 : 0.5)

            Spacer(minLength: 0)

            Button("Remove") { service.removeRule(id: item.id) }
                .controlSize(.small)
                .accessibilityLabel("Remove the breakpoint for \(rule.host)")
        }
    }

    /// The rest of the rule in one secondary line — what it is aimed at
    /// beyond the host, in the same words the fields that made it use.
    private static func summary(of rule: BreakpointRule) -> String {
        let methods = rule.methods.isEmpty ? "Any method" : rule.methods.joined(separator: ", ")
        if let path = rule.pathContains, !path.isEmpty {
            return "\(methods) · path contains \(path)"
        }
        return "\(methods) · any path"
    }

    private var methodMenu: some View {
        Menu {
            Button("Any method") { form.methods.removeAll() }
            Divider()
            ForEach(Self.commonMethods, id: \.self) { method in
                Toggle(method, isOn: Binding(
                    get: { form.methods.contains(method) },
                    set: { isOn in
                        if isOn { form.methods.insert(method) } else { form.methods.remove(method) }
                    }
                ))
            }
        } label: {
            Text(methodLabel)
        }
        // Without it the menu fills the Form's value column and shoves the
        // Add button off the row; with it the label below keeps it short.
        .fixedSize()
    }

    /// Never longer than "3 methods": the menu's width follows its label, and
    /// a label listing five verbs pushed the Add button out of the row.
    private var methodLabel: String {
        let selected = Self.commonMethods.filter { form.methods.contains($0) }
        switch selected.count {
        case 0: return "Any method"
        case 1, 2: return selected.joined(separator: ", ")
        default: return "\(selected.count) methods"
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Editing

    private func add() {
        guard form.canSubmit else { return }

        // Validation, canonicalisation and the duplicate check all live in
        // `BreakpointRuleEntry`, which the service's Add runs (it is also what
        // persists and pushes the rules) and the note below the form is
        // derived from. This view had its own copy of each for a day; two
        // implementations of "is this the same rule" is how the settings list
        // and the extension end up disagreeing about what is armed. A URL
        // pasted into the host field is refused by name there, because "cannot
        // match" would leave the user staring at a host that looks valid.
        //
        // Fixed order, so a rule is stored the same way whichever order its
        // methods were ticked in.
        let methods = Self.commonMethods.filter { form.methods.contains($0) }
        let refusal = service.addRule(host: form.host, pathContains: form.pathContains, methods: methods)
        form.submitted(accepted: refusal == nil)
    }

    private func disarmAll() {
        // Ids snapshotted first: each call republishes `rules`, and iterating
        // the live array while it is being replaced is the kind of thing that
        // works until the service starts compacting the list. Ids rather than
        // indices for the same reason the list is keyed on them — an index is
        // only valid until something before it moves.
        let armed = service.rules.filter(\.rule.enabled).map(\.id)
        for id in armed {
            service.setRuleEnabled(false, id: id)
        }
    }
}

// The host validation that used to sit here (`BreakpointHostEntry`) was a
// second, unused spelling of the rule text the service applies — and it had
// already drifted from it. There is one now: `BreakpointRuleEntry` (Utils).

#Preview {
    BreakpointSettingsView()
        .frame(width: 700, height: 620)
}
