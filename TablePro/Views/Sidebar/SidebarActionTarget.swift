//
//  SidebarActionTarget.swift
//  TablePro
//

import AppKit
import Foundation
import TableProPluginKit

@MainActor
struct SidebarActionTarget {
    let scope: DatabaseScope
    let host: MainContentCoordinator?

    private var isHostConnection: Bool {
        host?.connectionId == scope.connectionId
    }

    var connection: DatabaseConnection? {
        if isHostConnection, let host { return host.connection }
        return DatabaseManager.shared.session(for: scope.connectionId)?.connection
            ?? ConnectionStorage.shared.loadConnection(id: scope.connectionId)
    }

    var databaseType: DatabaseType? {
        connection?.type
    }

    var safeModeLevel: SafeModeLevel {
        if isHostConnection, let host { return host.safeModeLevel }
        return DatabaseManager.shared.session(for: scope.connectionId)?.safeModeLevel
            ?? connection?.safeModeLevel
            ?? .silent
    }

    var isReadOnly: Bool {
        safeModeLevel.blocksAllWrites
    }

    var coordinator: MainContentCoordinator? {
        guard let host else { return nil }
        guard host.connectionId != scope.connectionId else { return host }
        let tabGroup = Set((host.contentWindow?.tabbedWindows ?? []).map(ObjectIdentifier.init))
        let sibling = MainContentCoordinator.allActiveCoordinators().first { candidate in
            guard candidate.connectionId == scope.connectionId,
                  let window = candidate.contentWindow else { return false }
            return tabGroup.contains(ObjectIdentifier(window))
        }
        return sibling ?? host
    }

    func connectionScoped(to database: String) -> DatabaseConnection? {
        guard var connection else { return nil }
        connection.database = database
        return connection
    }
}
