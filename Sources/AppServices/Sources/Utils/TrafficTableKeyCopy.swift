//
//  TrafficTableKeyCopy.swift
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
//  What Help says about the traffic table's keys — ↑ ↓, ⇧, Esc and Delete. The
//  rules are `TrafficTableKeys`, `TrafficTableNavigation` and
//  `TrafficDetailDebounce`; every sentence here is checked against them in
//  TrafficTableKeyCopyTests, and the numbers in it are read from them.
//

import Foundation

public enum TrafficTableKeyCopy {
    /// Help's heading over `helpBullets`, in the Capture topic.
    public static let heading = "Moving through the list with the keyboard"

    /// How long the detail pane waits after the last arrow key, in whole
    /// milliseconds (`TrafficDetailDebounce.defaultInterval`).
    public static var detailDelayMilliseconds: Int {
        Int((TrafficDetailDebounce<Int>.defaultInterval * 1000).rounded())
    }

    public static var helpBullets: [String] {
        [
            "↓ and ↑ select the request below or above the selection, and the list scrolls to keep it in view. With nothing selected, ↓ starts at the top of the list and ↑ at the bottom. At the first or the last request the selection stays where it is — it does not wrap around.",
            "⇧↓ and ⇧↑ grow the selection one request at a time from where it started, and shrink it again on the way back. ⇧-click selects every request from that same starting point to the one you click; ⌘-click adds or removes one.",
            "A click shows its request in the detail pane at once. With the arrow keys the pane waits until you stop — \(detailDelayMilliseconds) ms after the last key, and never while an arrow is held down — so holding ↓ to skim the list opens only the request you stop on and, on the free version, uses at most one of the \(FreeTier.httpsSessionDetailsPerLaunch) free HTTPS inspections, not one for every request it passes.",
            "With several requests selected, the detail pane shows the one you clicked or moved to last.",
            "Esc deselects everything and closes the detail pane — also while you are reading a body or headers in it. Delete (or ⌦) removes the selected requests from the list at once, without asking; a copy you saved stays in Saved Sessions.",
            "These keys belong to the list while it has the keyboard — after you click a request, for example. Everywhere else they keep their own meaning: in the search field ↓ walks its suggestions and Esc clears it; in a body or headers the arrows move the text cursor; in the sidebar and in a WebSocket's message list they move that list's own selection; and while a sheet or an alert is open, they are its keys. Held with ⌘, ⌥ or ⌃, an arrow, Esc or Delete is never taken by the list.",
        ]
    }
}
