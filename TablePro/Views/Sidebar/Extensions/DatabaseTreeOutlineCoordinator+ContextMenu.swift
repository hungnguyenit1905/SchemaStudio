//
//  DatabaseTreeOutlineCoordinator+ContextMenu.swift
//  TablePro
//

import AppKit
import Observation
import SwiftUI
import TableProPluginKit

extension DatabaseTreeOutlineCoordinator {
    /// The view model of the node's own connection. Created on demand because a
    /// connection can be expanded in the tree long before it has a window.
    func viewModel(for connectionId: UUID) -> SidebarViewModel? {
        if connectionId == self.connectionId, let viewModel { return viewModel }
        guard let context = context(for: connectionId) else { return nil }
        return SidebarViewModel.forConnection(
            connectionId,
            databaseType: context.databaseType,
            selectedTables: selectedTablesBinding
        )
    }

    private var selectedTablesBinding: Binding<Set<DatabaseTreeTableRef>> {
        Binding(
            get: { [weak self] in self?.windowState?.selectedTables ?? [] },
            set: { [weak self] newValue in self?.windowState?.selectedTables = newValue }
        )
    }

    func rowContext(for node: DatabaseTreeNode) -> DatabaseTreeRowContext {
        let context = node.connectionId.flatMap { self.context(for: $0) }
        let nodeConnectionId = node.connectionId ?? connectionId
        return DatabaseTreeRowContext(
            databaseType: context?.databaseType ?? databaseType,
            activeDatabase: activeDatabase(for: nodeConnectionId),
            activeSchema: nodeConnectionId == connectionId ? activeSchema : nil,
            systemSchemas: context?.systemSchemas ?? [],
            pendingTruncates: pendingTruncates,
            pendingDeletes: pendingDeletes,
            connectionStatus: context?.status ?? .disconnected,
            isExternalSchema: { database, schema in
                ExternalSchemaTracker.shared.isExternal(
                    connectionId: nodeConnectionId,
                    database: database,
                    schema: schema
                )
            }
        )
    }

    /// Write actions read the safe mode of the node's connection, never the
    /// window's: the tree can show a read-only connection inside a window bound
    /// to a writable one.
    func rowActions(for node: DatabaseTreeNode) -> DatabaseTreeRowActions {
        let nodeConnectionId = node.connectionId ?? connectionId
        let context = self.context(for: nodeConnectionId)
        let isReadOnly = context?.safeModeLevel.blocksAllWrites
            ?? (mainCoordinator?.safeModeLevel.blocksAllWrites ?? false)
        return DatabaseTreeRowActions(
            coordinator: mainCoordinator,
            isReadOnly: isReadOnly,
            selectedTables: { [weak self] connectionId in
                Set((self?.selectedRefs() ?? []).filter { $0.connectionId == connectionId }.map(\.table))
            },
            activate: { [weak self] ref in await self?.activate(ref) },
            setActiveDatabase: { [weak self] in self?.setActiveDatabase($0) },
            setActiveSchema: { [weak self] database, schema in self?.setActiveSchema(database: database, schema: schema) },
            refreshDatabase: { [weak self] in self?.refreshDatabase($0, connectionId: nodeConnectionId) },
            refreshObjects: { [weak self] database, schema in
                self?.refreshObjects(database: database, schema: schema, connectionId: nodeConnectionId)
            },
            showRoutineDDL: { [weak self] routine in self?.mainCoordinator?.showRoutineDDL(routine) },
            batchToggleTruncate: { [weak self] connectionId, tableNames in
                self?.viewModel(for: connectionId)?
                    .batchToggleTruncate(connectionId: connectionId, tableNames: tableNames)
            },
            batchToggleDelete: { [weak self] connectionId, tableNames in
                self?.viewModel(for: connectionId)?
                    .batchToggleDelete(connectionId: connectionId, tableNames: tableNames)
            },
            connect: { [weak self] connection in self?.connect(connection) },
            disconnect: { [weak self] connection in self?.disconnect(connection) },
            refreshConnection: { [weak self] connection in self?.refreshConnection(connection) },
            removeRecent: { [weak self] ref in
                self?.sidebarState(for: ref.connectionId)?
                    .removeRecentTable(database: ref.database, schema: ref.schema, name: ref.table.name)
            },
            clearRecents: { [weak self] in
                guard let self else { return }
                self.sidebarState(for: nodeConnectionId)?
                    .clearRecentTables(inDatabase: self.activeDatabase(for: nodeConnectionId))
            }
        )
    }

    func makeCell() -> DatabaseTreeCellView {
        let cell = DatabaseTreeCellView()
        cell.identifier = Self.cellIdentifier
        return cell
    }
}

extension DatabaseTreeOutlineCoordinator {
    func connect(_ connection: DatabaseConnection) {
        guard DatabaseManager.shared.activeSessions[connection.id]?.driver == nil else { return }
        Task { @MainActor in
            try? await DatabaseManager.shared.connectToSession(connection)
        }
    }

    func disconnect(_ connection: DatabaseConnection) {
        ConnectionTreeState.shared.expandedConnectionIds.remove(connection.id)
        if let node = nodeCache[DatabaseTreeNode.connectionNodeId(connection.id)] {
            setExpanded(node, false)
        }
        Task { @MainActor in
            await DatabaseManager.shared.disconnectSession(connection.id)
        }
    }

    func refreshConnection(_ connection: DatabaseConnection) {
        guard let context = context(for: connection.id), context.isConnected else { return }
        Task {
            await service.refreshDatabases(connectionId: connection.id, databaseType: context.databaseType)
        }
    }
}
