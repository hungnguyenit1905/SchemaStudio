//
//  WindowCloseDisconnectPolicy.swift
//  TablePro
//

import Foundation

/// Decides whether closing a window should end its connection's session.
///
/// A window used to be the only thing that kept a session alive, so "no windows
/// left" meant "nobody can see this connection". The sidebar tree spans every
/// saved connection in every window, so it now holds sessions too: a connection
/// can be connected without ever having had a window of its own, and closing
/// its last tab while it still shows connected in every other window's tree
/// would kill the session under the tree with no visible cause.
///
/// The tree only counts while some editor window is left to draw it. Once the
/// last one closes there is no tree on screen, and a remembered expansion would
/// hold a session nobody can reach or close.
internal enum WindowCloseDisconnectPolicy {
    internal static func shouldDisconnect(
        hasRemainingWindowsForConnection: Bool,
        isExpandedInTree: Bool,
        hasAnyRemainingWindow: Bool
    ) -> Bool {
        if hasRemainingWindowsForConnection { return false }
        guard hasAnyRemainingWindow else { return true }
        return !isExpandedInTree
    }
}
