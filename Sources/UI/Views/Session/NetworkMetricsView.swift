//
//  NetworkMetricsView.swift
//  ReqRes
//
//  Created by OloApps on 2/12/25.
//
//  Copyright © 2025 OloApps. All rights reserved.
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
    
    init(session: SessionCodable) {
        self.session = session
        
        // Calculate phases duration
        queuedDuration = calculateDuration(session.startTime.doubleValue, session.connectTime.doubleValue)
        dnsDuration = calculateDuration(session.connectTime.doubleValue, session.connectedTime.doubleValue)
        tcpDuration = calculateDuration(session.connectedTime.doubleValue, session.handshakeEndTime.doubleValue)
        secureDuration = session.scheme == "https" ?
            calculateDuration(session.handshakeEndTime.doubleValue, session.reqStartTime.doubleValue) : 0
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
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Network Load")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                HStack(spacing: 32) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.circle")
                        Text("Upload: \(formatBytes(session.uploadTraffic.int64Value))")
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle")
                        Text("Download: \(formatBytes(session.downloadFlow.int64Value))")
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
                
                let dnsOffset = 0.0
                TimelineItem(
                    label: "DNS",
                    duration: formatDuration(dnsDuration),
                    color: Color(Palette.networkDNS),
                    startOffset: calculateOffset(dnsOffset),
                    progress: calculateProgress(dnsDuration)
                )
                
                let tcpOffset = dnsOffset + dnsDuration
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
