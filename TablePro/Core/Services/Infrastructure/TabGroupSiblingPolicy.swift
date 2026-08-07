//
//  TabGroupSiblingPolicy.swift
//  TablePro
//

import Foundation

/// Picks the window whose tab group a newly opened tab joins.
///
/// The order is the point. `NSApp.windows` is roughly creation order, so
/// choosing the first match from it answers "whichever window was made first"
/// rather than "the one the user is looking at", and a tab opened from a
/// sidebar lands in a group on another screen. Preference runs from the most
/// specific evidence of intent to the least: the window the action came from,
/// then the window with focus, then the main window, and only then front-to-back
/// order as a last resort.
internal enum TabGroupSiblingPolicy {
    internal static func choose<Window>(
        anchor: Window?,
        keyWindow: Window?,
        mainWindow: Window?,
        frontToBack: [Window],
        matches: (Window) -> Bool
    ) -> Window? {
        for preferred in [anchor, keyWindow, mainWindow] {
            if let preferred, matches(preferred) { return preferred }
        }
        return frontToBack.first(where: matches)
    }
}
