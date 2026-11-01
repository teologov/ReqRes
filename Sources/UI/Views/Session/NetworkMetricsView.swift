//
//  NetworkMetricsView.swift
//  ReqRes
//
//  Created by OloApps on 2/12/25.
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

import MCPKit
import SwiftUI
import XReqResCore

struct TimelineItem: View {
    let label: String
    let duration: String
    let color: Color
    let startOffset: Double   // Relative start offset (0.0 to 1.0)
    let progress: Double      // Relative width (0.0 to 1.0)
    
    // Local state for hover and animation
    @State private var isHovering = false
    @State private var animatedProgress = 0.0
    
    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(width: 70, alignment: .leading)
                .foregroundColor(.secondary)
                .font(.system(.callout, design: .monospaced))
            
            GeometryReader { geometry in
                // The bar is a RoundedRectangle that fills with the provided color,
                // then darkens when hovered over.
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .brightness(isHovering ? -0.1 : 0)
                    // Animate the bar width using animatedProgress, not the raw progress.
                    .frame(width: max(3, geometry.size.width * animatedProgress))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 14)
                    .offset(x: geometry.size.width * startOffset)
                    // Detect hover events.
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isHovering = hovering
                        }
                    }
                    // Animate the bar width on appear.
                    .onAppear {
                        withAnimation(.easeOut(duration: 0.5)) {
                            animatedProgress = progress
                        }
                    }
                    // Animate if progress changes dynamically.
                    .onChange(of: progress) { _, newValue in
                        withAnimation(.easeOut(duration: 0.5)) {
                            animatedProgress = newValue
                        }
                    }
            }
            .frame(height: 14)
            
            Text(duration)
                .frame(width: 70, alignment: .trailing)
                .foregroundColor(.secondary)
                .font(.system(.callout, design: .monospaced))
        }
    }
}

struct NetworkMetricsView: View {
    let session: SessionCodable
    
    private var queuedDuration: Double = 0
    private var dnsDuration: Double = 0
    private var tcpDuration: Double = 0
    private var secureDuration: Double = 0
    private var requestDuration: Double = 0
    private var waitingDuration: Double = 0
    private var downloadDuration: Double = 0
    
    private var timelineStart: Double { session.startTime.doubleValue }

    /// False for an exchange that rode a connection an earlier request
    /// opened: it had no DNS, TCP or TLS of its own, and the pane says so in
    /// words instead of drawing three bars of nothing.
    private var showsConnectionSetup: Bool {
        RecordedExchangeCopy.showsConnectionSetup(reused: session.connectionReused, exchangeIndex: session.exchangeIndex)
    }
    
    init(session: SessionCodable) {
        self.session = session
        
        // Calculate phases duration
        queuedDuration = calculateDuration(session.startTime.doubleValue, session.connectStartTime.doubleValue)
        // A reused connection's setup phases are zero-length by construction
        // (core C2.7 anchors them at the exchange's own start); its "Secure"
        // span would be the microseconds between that start and the request
        // head, which is not a handshake. None of the three are drawn for it
        // (`RecordedExchangeCopy.showsConnectionSetup`), so none are summed.
        if showsConnectionSetup {
            dnsDuration = calculateDuration(session.connectStartTime.doubleValue, session.connectEndTime.doubleValue)
            tcpDuration = calculateDuration(session.connectEndTime.doubleValue, session.tlsEndTime.doubleValue)
            secureDuration = session.scheme == "https" ?
                calculateDuration(session.tlsEndTime.doubleValue, session.reqStartTime.doubleValue) : 0
        }
        requestDuration = calculateDuration(session.reqStartTime.doubleValue, session.rspStartTime.doubleValue)
        waitingDuration = calculateDuration(session.rspStartTime.doubleValue, session.downloadStartTime.doubleValue)
        downloadDuration = calculateDuration(session.downloadStartTime.doubleValue, session.downloadEndTime.doubleValue)
    }
    
    private func calculateDuration(_ start: Double, _ end: Double) -> Double {
        max(0, end - start)
    }
    
    private var totalDuration: Double {
        queuedDuration + dnsDuration + tcpDuration + secureDuration +
        requestDuration + waitingDuration + downloadDuration
    }
    
    private func calculateOffset(_ previousDurations: Double) -> Double {
        previousDurations / totalDuration
    }
    
    private func calculateProgress(_ duration: Double, minimum: Double = 0.01) -> Double {
        if duration <= 0 || abs(duration) < 0.000001 {
            return minimum
        }
        return min(duration / totalDuration, 0.95)
    }
    
    private func formatDuration(_ duration: Double) -> String {
        let ms = duration * 1000
        return String(format: "%.1f ms", abs(ms))
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Where the connection went (destination-map UX spec §5.5): the address
    /// the extension recorded and the country it resolves to, in
    /// `TimelineItem`'s label typography — `104.18.32.7 · Germany`,
    /// `127.0.0.1 · This Mac`, `— · Unknown` when the core recorded no
    /// address. The address is selectable; the country is the resolver's
    /// cached answer, the same one the traffic list filters by.
    private var serverRow: some View {
        let destination = DestinationResolver.shared.destination(for: session)
        return HStack(spacing: 12) {
            Text("Server")
                .frame(width: 70, alignment: .leading)
                .foregroundColor(.secondary)
                .font(.system(.callout, design: .monospaced))

            HStack(spacing: 6) {
                Text(session.remoteAddressText ?? "—")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                Text("·")
                    .foregroundColor(.secondary)
                Text(CountryPresentation.title(for: destination))
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .help(DestinationCopy.classDescription(destination, tableFailure: DestinationResolver.shared.tableFailureReason) ?? DestinationCopy.whatACountryMeans)

            Spacer(minLength: 0)
        }
    }

    /// What the row spoke (protocol-engine doc §S9): HTTP/1.1, HTTP/2, a
    /// WebSocket after its upgrade — a row, not a table column, because the
    /// table has no width to spare. The label is text (and an HTTP/2 row's
    /// symbol says "several streams on one connection"); the caption is
    /// `SessionProtocolPresentation`'s, so an agent reads the same words.
    private var protocolRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Protocol")
                .frame(width: 70, alignment: .leading)
                .foregroundColor(.secondary)
                .font(.system(.callout, design: .monospaced))
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text(verbatim: session.protocolLabel)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: Self.symbolName(session.sessionProtocol))
                        .foregroundColor(.secondary)
                }
                .font(.callout)
                if let caption = session.protocolCaption {
                    Text(caption)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Protocol: \(session.protocolLabel)")
    }

    static func symbolName(_ proto: SessionProtocol?) -> String {
        switch proto {
        case .http2: return "square.stack.3d.up"
        case .webSocket: return "arrow.left.arrow.right"
        case .relay: return "lock.slash"
        case .http1: return "arrow.right"
        case nil: return "questionmark.circle"
        }
    }

    /// "40 MB (16 MB kept)" when the capture kept only part of the body — the
    /// transfer size is the whole body as sent; what the Body tab shows is
    /// not. Both numbers in the 1024-based units the 16 MB limit is stated
    /// in, so they add up with the Body tab's notice; a whole body keeps the
    /// pane's usual formatter.
    private func loadText(_ total: Int64, notRetained: Int64) -> String {
        guard notRetained > 0 else { return formatBytes(total) }
        return "\(RecordedExchangeCopy.binaryBytes(total)) (\(RecordedExchangeCopy.binaryBytes(max(0, total - notRetained))) kept)"
    }

    /// In place of the DNS / TCP / Secure bars for a reused connection: the
    /// label ("Reused connection · request 3 on it") and why nothing is drawn.
    private func reusedConnectionRow(_ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Setup")
                .frame(width: 70, alignment: .leading)
                .foregroundColor(.secondary)
                .font(.system(.callout, design: .monospaced))
            VStack(alignment: .leading, spacing: 2) {
                Label(label, systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout)
                Text(RecordedExchangeCopy.reusedExplanation)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Network Load")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                HStack(spacing: 32) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.circle")
                        Text("Upload: " + loadText(session.requestBytes.int64Value, notRetained: session.reqBodyTruncatedBytes))
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle")
                        Text("Download: " + loadText(session.responseBytes.int64Value, notRetained: session.rspBodyTruncatedBytes))
                            .foregroundColor(.secondary)
                    }
                }
                
                Text("Scheduling")
                    .font(.headline)
                    .padding(.top, 8)
                TimelineItem(
                    label: "Queued",
                    duration: formatDuration(queuedDuration),
                    color: .gray,
                    startOffset: 0,
                    progress: calculateProgress(queuedDuration)
                )
                
                Text("Connection")
                    .font(.headline)
                    .padding(.top, 8)

                protocolRow

                serverRow

                let dnsOffset = 0.0
                let tcpOffset = dnsOffset + dnsDuration
                if let reused = session.reusedConnectionLabel {
                    reusedConnectionRow(reused)
                } else {
                    TimelineItem(
                        label: "DNS",
                        duration: formatDuration(dnsDuration),
                        color: Color(Palette.networkDNS),
                        startOffset: calculateOffset(dnsOffset),
                        progress: calculateProgress(dnsDuration)
                    )

                    TimelineItem(
                        label: "TCP",
                        duration: formatDuration(tcpDuration),
                        color: Color(Palette.networkTCP),
                        startOffset: calculateOffset(tcpOffset),
                        progress: calculateProgress(tcpDuration)
                    )

                    if session.scheme == "https" {
                        let secureOffset = tcpOffset + tcpDuration
                        TimelineItem(
                            label: "Secure",
                            duration: formatDuration(secureDuration),
                            color: Color(Palette.networkSecure),
                            startOffset: calculateOffset(secureOffset),
                            progress: calculateProgress(secureDuration)
                        )
                    }
                }
                
                Text("Response")
                    .font(.headline)
                    .padding(.top, 8)
                
                let requestOffset = tcpOffset + tcpDuration + secureDuration
                TimelineItem(
                    label: "Request",
                    duration: formatDuration(requestDuration),
                    color: Color(Palette.networkRequest),
                    startOffset: calculateOffset(requestOffset),
                    progress: calculateProgress(requestDuration)
                )
                
                let waitingOffset = requestOffset + requestDuration
                TimelineItem(
                    label: "Waiting",
                    duration: formatDuration(waitingDuration),
                    color: Color(Palette.networkWaiting),
                    startOffset: calculateOffset(waitingOffset),
                    progress: calculateProgress(waitingDuration)
                )
                
                let downloadOffset = waitingOffset + waitingDuration
                TimelineItem(
                    label: "Download",
                    duration: formatDuration(downloadDuration),
                    color: Color(Palette.networkDownload),
                    startOffset: calculateOffset(downloadOffset),
                    progress: calculateProgress(downloadDuration)
                )
            }
            .padding()
        }
    }
}
