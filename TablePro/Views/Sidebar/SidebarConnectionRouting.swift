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

/// Which coordinator the sidebar's bottom bar acts through.
///
/// One connection can own several coordinators, one per tab window, and the
/// registry is keyed by `instanceId`, so picking "a coordinator of connection X"
/// out of the dictionary would give a different answer between runs. Only two
/// coordinators are ever nameable from a sidebar, and they are tried in order.
internal enum SidebarCoordinatorChoice: Equatable {
    case keyWindow
    case host
    case none
}

internal enum SidebarCoordinatorResolver {
    /// - Parameters:
    ///   - target: the connection selected in the tree.
    ///   - keyWindowConnectionId: connection of the coordinator in the key window.
    ///   - hostConnectionId: connection of the coordinator in the window drawing this sidebar.
    internal static func choice(
        target: UUID,
        keyWindowConnectionId: UUID?,
        hostConnectionId: UUID?
    ) -> SidebarCoordinatorChoice {
        if keyWindowConnectionId == target { return .keyWindow }
        if hostConnectionId == target { return .host }
        return .none
    }
}
