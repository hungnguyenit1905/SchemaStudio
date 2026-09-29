//
//  MainContentCoordinator+Scope.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    /// A tab's target, read only from the tab and its connection. It deliberately reads
    /// no window, toolbar or coordinator state, so moving the tab to another window
    /// cannot change what it queries.
    ///
    /// It resolves before a session exists, because a tab already knows its own database
    /// and the connection knows its saved default. Only the browse-cursor fallback, for a
    /// tab that never recorded one, needs a live session.
    func scope(for tab: QueryTab) -> DatabaseScope? {
        if let resolved = services.databaseManager.resolvedScope(
            database: tab.tableContext.databaseName,
            schema: tab.tableContext.schemaName,
            for: connectionId
        ) {
            return resolved
        }
        let database = tab.tableContext.databaseName.isEmpty
            ? connection.database
            : tab.tableContext.databaseName
        return DatabaseScope(
            connectionId: connectionId,
            database: database,
            schema: tab.tableContext.schemaName
        )
    }

    var selectedTabScope: DatabaseScope? {
        guard let tab = tabManager.selectedTab else { return browseScope }
        return scope(for: tab)
    }

    /// Where the sidebar is pointing. Correct for the object list and for seeding a new
    /// tab, never for an operation an open tab owns.
    var browseScope: DatabaseScope? {
        services.databaseManager.browseScope(for: connectionId)
    }

    var newWorkScope: DatabaseScope {
        let defaultDatabase = services.databaseManager.session(for: connectionId)?.resolvedBrowseDatabase
            ?? connection.database
        if let selected = windowSidebarState.selectedScope, selected.connectionId == connectionId {
            let manager = services.databaseManager
            let usable = selected.resolved(
                connectionExists: { _ in true },
                isDatabaseOpen: { database, id in manager.session(for: id) == nil || manager.isDatabaseOpen(database, for: id) }
            ) ?? selected
            return usable.databaseScope(defaultDatabase: defaultDatabase)
        }
        if let tabScope = selectedTabScope {
            return tabScope
        }
        return DatabaseScope(connectionId: connectionId, database: defaultDatabase, schema: nil)
    }
}
