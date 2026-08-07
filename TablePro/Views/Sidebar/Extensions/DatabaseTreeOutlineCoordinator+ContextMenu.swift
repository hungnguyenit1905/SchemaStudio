//
//  DatabaseTreeOutlineCoordinator+ContextMenu.swift
//  TablePro
//

import AppKit
import Observation
import TableProPluginKit

extension DatabaseTreeOutlineCoordinator {
    func rowContext() -> DatabaseTreeRowContext {
        DatabaseTreeRowContext(
            databaseType: databaseType,
            activeDatabase: activeDatabase,
            activeSchema: activeSchema,
            systemSchemas: systemSchemas,
            pendingTruncates: pendingTruncates,
            pendingDeletes: pendingDeletes,
            isExternalSchema: { [connectionId] database, schema in
                ExternalSchemaTracker.shared.isExternal(
                    connectionId: connectionId,
                    database: database,
                    schema: schema
                )
            }
        )
    }

    func rowActions() -> DatabaseTreeRowActions {
        DatabaseTreeRowActions(
            coordinator: mainCoordinator,
            isReadOnly: mainCoordinator?.safeModeLevel.blocksAllWrites ?? false,
            selectedTables: { [weak self] connectionId in
                Set((self?.selectedRefs() ?? []).filter { $0.connectionId == connectionId }.map(\.table))
            },
            activate: { [weak self] ref in await self?.activate(ref) },
            setActiveDatabase: { [weak self] in self?.setActiveDatabase($0) },
            setActiveSchema: { [weak self] database, schema in self?.setActiveSchema(database: database, schema: schema) },
            refreshDatabase: { [weak self] in self?.refreshDatabase($0) },
            refreshObjects: { [weak self] database, schema in self?.refreshObjects(database: database, schema: schema) },
            showRoutineDDL: { [weak self] routine in self?.mainCoordinator?.showRoutineDDL(routine) },
            batchToggleTruncate: { [weak self] connectionId, tableNames in
                self?.viewModel?.batchToggleTruncate(connectionId: connectionId, tableNames: tableNames)
            },
            batchToggleDelete: { [weak self] connectionId, tableNames in
                self?.viewModel?.batchToggleDelete(connectionId: connectionId, tableNames: tableNames)
            },
            removeRecent: { [weak self] ref in
                self?.sidebarState?.removeRecentTable(database: ref.database, schema: ref.schema, name: ref.table.name)
            },
            clearRecents: { [weak self] in
                self?.sidebarState?.clearRecentTables(inDatabase: self?.mainCoordinator?.browseDatabaseName)
            }
        )
    }

    func makeCell() -> DatabaseTreeCellView {
        let cell = DatabaseTreeCellView()
        cell.identifier = Self.cellIdentifier
        return cell
    }
}
