//
//  DatabaseLevel.swift
//  TablePro
//

import Foundation
import TableProPluginKit

@MainActor
struct DatabaseLevel {
    var supportsDatabaseSwitching: (DatabaseType) -> Bool
    var connectionMode: (DatabaseType) -> ConnectionMode

    static var live: DatabaseLevel {
        DatabaseLevel(
            supportsDatabaseSwitching: { PluginManager.shared.supportsDatabaseSwitching(for: $0) },
            connectionMode: { PluginManager.shared.connectionMode(for: $0) }
        )
    }

    func hasDatabaseLevel(_ type: DatabaseType) -> Bool {
        supportsDatabaseSwitching(type) && connectionMode(type) != .fileBased
    }
}
