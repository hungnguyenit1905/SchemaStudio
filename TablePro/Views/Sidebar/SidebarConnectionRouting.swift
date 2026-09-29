//
//  SidebarConnectionRouting.swift
//  TablePro
//
//  The sidebar shows every saved connection, so a click can land on a node that
//  belongs to a different connection than the window hosting the tree. These are
//  the resolution rules for that split, kept pure so they stay testable and so
//  they cannot drift into a chain of conditions inside a view.
//

import Foundation

/// Where a table opened from the tree should go.
internal enum SidebarTabRoute: Equatable {
    /// The node belongs to the window's own connection: keep the existing path
    /// through `MainContentCoordinator.openTableTab`, which owns the preview tab
    /// and the unsaved-work tab replacement guard.
    case currentWindowCoordinator
    /// The node belongs to another connection: a new tab bound to that
    /// connection, joined to the tab group the user is already looking at.
    case newTabForNodeConnection
}

internal enum SidebarTabRouter {
    internal static func route(nodeConnectionId: UUID, windowConnectionId: UUID) -> SidebarTabRoute {
        nodeConnectionId == windowConnectionId ? .currentWindowCoordinator : .newTabForNodeConnection
    }
}
