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
            defaultDatabase: activeDatabase(for: nodeConnectionId),
            systemSchemas: context?.systemSchemas ?? [],
            pendingTruncates: pendingTableOperations(for: nodeConnectionId).truncates,
            pendingDeletes: pendingTableOperations(for: nodeConnectionId).deletes,
            connectionStatus: context?.status ?? .disconnected,
            connectFailureMessage: connectFailure(for: nodeConnectionId),
            isExternalSchema: { database, schema in
                ExternalSchemaTracker.shared.isExternal(
                    connectionId: nodeConnectionId,
                    database: database,
                    schema: schema
                )
            },
            isDatabaseOpen: { database in
                DatabaseManager.shared.isDatabaseOpen(database, for: nodeConnectionId)
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
            selectedRefs: { [weak self] connectionId in
                Set((self?.selectedRefs() ?? []).filter { $0.connectionId == connectionId })
            },
            openDatabase: { [weak self] in self?.openDatabase($0, connectionId: nodeConnectionId) },
            closeDatabase: { [weak self] in self?.closeDatabase($0, connectionId: nodeConnectionId) },
            refreshDatabase: { [weak self] in self?.refreshDatabase($0, connectionId: nodeConnectionId) },
            openDataTransfer: { [weak self] database in
                self?.mainCoordinator?.openDataTransferWizard(
                    preselectedScope: DatabaseScope(
                        connectionId: nodeConnectionId,
                        database: database,
                        schema: nil
                    )
                )
            },
            openDataGeneration: { [weak self] database in
                self?.mainCoordinator?.openDataGenerationWizard(
                    preselectedScope: DatabaseScope(
                        connectionId: nodeConnectionId,
                        database: database,
                        schema: nil
                    )
                )
            },
            openDuplicateTable: { [weak self] ref in
                self?.mainCoordinator?.openDuplicateTableSheet(
                    ref.table,
                    scope: DatabaseScope(
                        connectionId: ref.connectionId,
                        database: ref.database,
                        schema: ref.schema ?? ref.table.schema
                    )
                )
            },
            openStructure: { [weak self] ref in
                self?.open(ref, activateGridFocus: true, showStructure: true)
            },
            refreshObjects: { [weak self] database, schema in
                self?.refreshObjects(database: database, schema: schema, connectionId: nodeConnectionId)
            },
            showRoutineDDL: { [weak self] routine in self?.mainCoordinator?.showRoutineDDL(routine) },
            batchToggleTruncate: { [weak self] refs in
                self?.hostViewModel(for: refs)?.batchToggleTruncate(tables: refs)
            },
            batchToggleDelete: { [weak self] refs in
                self?.hostViewModel(for: refs)?.batchToggleDelete(tables: refs)
            },
            connect: { [weak self] connection in self?.connect(connection) },
            disconnect: { [weak self] connection in self?.disconnect(connection) },
            refreshConnection: { [weak self] connection in self?.refreshConnection(connection) },
            editConnection: { [weak self] connection in self?.editConnection(connection) },
            newQuery: { [weak self] connection in self?.newQuery(connection) },
            newDatabase: { [weak self] connection in
                self?.mainCoordinator?.activeSheet = .createDatabase(connectionId: connection.id)
            },
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

    func pendingTableOperations(
        for connectionId: UUID
    ) -> (truncates: Set<DatabaseTreeTableRef>, deletes: Set<DatabaseTreeTableRef>) {
        if connectionId == self.connectionId {
            return (pendingTruncates[connectionId] ?? [], pendingDeletes[connectionId] ?? [])
        }
        let session = DatabaseManager.shared.session(for: connectionId)
        return (session?.pendingTruncates ?? [], session?.pendingDeletes ?? [])
    }

    private func hostViewModel(for refs: [DatabaseTreeTableRef]) -> SidebarViewModel? {
        if let viewModel { return viewModel }
        return refs.first.flatMap { self.viewModel(for: $0.connectionId) }
    }

    func makeCell() -> DatabaseTreeCellView {
        let cell = DatabaseTreeCellView()
        cell.identifier = Self.cellIdentifier
        return cell
    }
}

extension DatabaseTreeOutlineCoordinator {
    /// The single connect path for the tree, shared by expand-to-connect, the
    /// context menu and the retry button. `connectToSession` owns the attempt
    /// registry, so the tree adds nothing but the failure message, which the
    /// session cannot carry: a failed attempt removes its own session entry.
    func connect(_ connection: DatabaseConnection) {
        guard DatabaseManager.shared.activeSessions[connection.id]?.driver == nil else { return }
        ConnectionTreeState.shared.clearConnectFailure(connection.id)
        ConnectionTreeState.shared.expandedConnectionIds.insert(connection.id)
        Task { @MainActor in
            do {
                try await DatabaseManager.shared.connectToSession(connection)
            } catch is CancellationError {
                ConnectionTreeState.shared.clearConnectFailure(connection.id)
            } catch {
                recordConnectFailureIfStillOurs(connection.id, error: error)
            }
        }
    }

    /// An attempt that genuinely failed has already removed its own session
    /// entry, so a surviving entry means a newer attempt owns the connection
    /// now: it either won the driver or is still connecting. A late loser that
    /// wrote its error anyway would paint a connected connection red, which is
    /// the shape of bug this area has shipped four times.
    private func recordConnectFailureIfStillOurs(_ connectionId: UUID, error: Error) {
        guard DatabaseManager.shared.activeSessions[connectionId] == nil else { return }
        ConnectionTreeState.shared.recordConnectFailure(
            connectionId, message: error.localizedDescription
        )
    }

    /// A failure describes the last attempt, not the connection. Reconnecting
    /// from the welcome window or through the health monitor never touches the
    /// tree's record, so a live session is what retires the message.
    func connectFailure(for connectionId: UUID) -> String? {
        guard DatabaseManager.shared.activeSessions[connectionId]?.driver == nil else { return nil }
        return ConnectionTreeState.shared.connectFailures[connectionId]
    }

    func disconnect(_ connection: DatabaseConnection) {
        Task { @MainActor in
            guard await DatabaseCloseFlow.closeConnection(connection.id, anchor: outlineView?.window) else { return }
            ConnectionTreeState.shared.expandedConnectionIds.remove(connection.id)
            ConnectionTreeState.shared.clearConnectFailure(connection.id)
            if let node = nodeCache[DatabaseTreeNode.connectionNodeId(connection.id)] {
                setExpanded(node, false)
            }
        }
    }

    func editConnection(_ connection: DatabaseConnection) {
        WindowOpener.shared.openConnectionForm(editing: connection.id)
    }

    /// A query tab for the node's own connection, joined to the tab group the
    /// user is looking at, the same rule table nodes follow.
    func newQuery(_ connection: DatabaseConnection) {
        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .query,
            intent: .newEmptyTab
        )
        WindowManager.shared.openTab(payload: payload, tabGroup: .shared, anchor: outlineView?.window)
    }

    func refreshConnection(_ connection: DatabaseConnection) {
        guard let context = context(for: connection.id), context.isConnected else { return }
        Task {
            await service.refreshDatabases(connectionId: connection.id, databaseType: context.databaseType)
        }
    }
}
