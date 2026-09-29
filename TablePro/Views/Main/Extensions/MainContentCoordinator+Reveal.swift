//
//  MainContentCoordinator+Reveal.swift
//  TablePro
//

import Foundation
import os

private let revealLogger = Logger(subsystem: "com.SchemaStudio", category: "SidebarReveal")

extension MainContentCoordinator {
    func revealInSidebar(database: String, schema: String? = nil, connectionId: UUID? = nil) {
        let owner = connectionId ?? self.connectionId
        Task { @MainActor in
            do {
                try await services.databaseManager.markDatabaseOpen(database, for: owner)
            } catch {
                revealLogger.warning(
                    "Revealing \(database, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                AlertHelper.showErrorSheet(
                    title: String(format: String(localized: "Could not open %@"), database),
                    message: error.localizedDescription,
                    window: contentWindow
                )
                return
            }
            ConnectionTreeState.shared.expandedConnectionIds.insert(owner)
            windowSidebarState.expandedTreeDatabases.insert(ConnectionDatabaseKey(connectionId: owner, database: database))
            if let schema {
                windowSidebarState.expandedTreeDatabaseSchemas.insert(
                    ConnectionSchemaKey(connectionId: owner, database: database, schema: schema)
                )
            }
            windowSidebarState.selectedScope = SidebarScope(connectionId: owner, database: database, schema: schema)
        }
    }
}
