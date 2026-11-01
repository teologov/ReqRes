//
//  MCPDestinationAggregation.swift
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
//  `list_destinations` (destination-map UX spec §8.3): where the captured
//  requests went, grouped by destination, over the SAME filters as
//  `list_sessions` — so `app=claude` answers "where does this tool send
//  data". Pure aggregation over session summaries: O(5,000) per call is
//  nothing, and it needs no new seam into the app. The user's own location
//  (`OriginEstimate`) is never part of this report (§0, §11).
//

import Foundation

/// A host or app name with how many of the destination's requests it made.
public struct MCPCountedName: Codable, Equatable {
    public var name: String
    public var requests: Int

    public init(name: String, requests: Int) {
        self.name = name
        self.requests = requests
    }
}

/// One destination in the report.
public struct MCPDestinationSummary: Codable, Equatable {
    /// The `TrafficDestination` token: `US`, `local`, `mac`, `unknown`.
    public var country: String
    /// The English name, or the class label (This Mac, Local Network, Unknown).
    public var name: String
    public var requests: Int
    /// Request plus response body bytes, as the summaries carry them.
    public var bytes: Int64
    public var hostCount: Int
    public var appCount: Int
    /// ≤ 3 in the list; ≤ 20 when `country=` asks for one destination.
    public var topHosts: [MCPCountedName]
    /// ≤ 3 in the list; ≤ 10 when `country=` asks for one destination.
    public var topApps: [MCPCountedName]

    public init(country: String, name: String, requests: Int, bytes: Int64, hostCount: Int, appCount: Int, topHosts: [MCPCountedName], topApps: [MCPCountedName]) {
        self.country = country
        self.name = name
        self.requests = requests
        self.bytes = bytes
        self.hostCount = hostCount
        self.appCount = appCount
        self.topHosts = topHosts
        self.topApps = topApps
    }
}

public struct MCPDestinationsReport: Codable, Equatable {
    /// Requests that matched the filter — the ones the rows add up to.
    public var totalRequests: Int
    /// Requests desc; Unknown last whatever its count.
    public var destinations: [MCPDestinationSummary]
    /// What a country means here, and the data credit — the same sentence
    /// Help and Settings show (`DestinationCopy.whatACountryMeans`).
    public var note: String

    /// Matching requests left OUT because they failed before connecting to
    /// any server (protocol PRD 3.4): they went nowhere, so counting them as
    /// Unknown would inflate the one row that says "could not place". Nil
    /// from an app that predates the field; 0 when none were left out.
    public var neverConnected: Int?

    public init(totalRequests: Int, destinations: [MCPDestinationSummary], note: String, neverConnected: Int? = nil) {
        self.totalRequests = totalRequests
        self.destinations = destinations
        self.note = note
        self.neverConnected = neverConnected
    }
}

public enum MCPDestinationAggregation {
    public static let listHostLimit = 3
    public static let listAppLimit = 3
    public static let detailHostLimit = 20
    public static let detailAppLimit = 10

    /// Names in the report are English regardless of the Mac's language: an
    /// agent's context may be anywhere, and its user asked in the language
    /// the tool speaks.
    public static let reportLocale = Locale(identifier: "en_US")

    /// The note every report ends with.
    public static var note: String {
        "\(DestinationCopy.whatACountryMeans) \(DestinationCopy.agentAttribution)"
    }

    /// Applies `filter` to `summaries`, groups what is left by destination
    /// and ranks it. `filter.country` set means the agent asked about ONE
    /// destination, so that row carries its fuller host and app lists.
    public static func report(summaries: [MCPSessionSummary], filter: MCPSessionFilter, redactor: MCPRedactor? = nil) -> MCPDestinationsReport {
        var index = DestinationIndex()
        var neverConnected = 0
        for session in summaries where filter.matches(session, redactor: redactor) {
            // A request that failed before connecting went nowhere: it is
            // not a destination, known or Unknown. Counted, and said.
            if session.failureFacts?.neverConnected == true {
                neverConnected += 1
                continue
            }
            index.add(
                destination: destination(of: session),
                host: session.host,
                bytes: bytes(of: session),
                app: session.app
            )
        }
        let detail = filter.country != nil
        let hostLimit = detail ? detailHostLimit : listHostLimit
        let appLimit = detail ? detailAppLimit : listAppLimit
        let rows = index.sorted().map { entry in
            MCPDestinationSummary(
                country: entry.destination.token,
                name: CountryPresentation.title(for: entry.destination, locale: reportLocale),
                requests: entry.requests,
                bytes: entry.bytes,
                hostCount: entry.hostCount,
                appCount: entry.appCount,
                topHosts: entry.topHosts(hostLimit).map { MCPCountedName(name: $0.name, requests: $0.requests) },
                topApps: entry.topApps(appLimit).map { MCPCountedName(name: $0.name ?? ProcessIdentity.unknownLabel, requests: $0.requests) }
            )
        }
        return MCPDestinationsReport(totalRequests: index.totalRequests, destinations: rows, note: note, neverConnected: neverConnected)
    }

    /// A summary's destination: its token parsed back, Unknown when it
    /// carries none (the adapter omits the token for Unknown) or something
    /// unparseable.
    static func destination(of session: MCPSessionSummary) -> TrafficDestination {
        session.country.flatMap(TrafficDestination.parseToken) ?? .unknown
    }

    /// Request plus response body sizes — the transfer figures a summary has.
    static func bytes(of session: MCPSessionSummary) -> Int64 {
        Int64(max(0, session.requestBodySize ?? 0)) + Int64(max(0, session.responseBodySize ?? 0))
    }
}
