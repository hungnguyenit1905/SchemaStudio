//
//  DatabaseTreeRowView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

struct DatabaseTreeRowActions {
    let coordinator: MainContentCoordinator?
    let isReadOnly: Bool
    let selectedRefs: (UUID) -> Set<DatabaseTreeTableRef>
    let openDatabase: (String) -> Void
    let closeDatabase: (String) -> Void
    let refreshDatabase: (String) -> Void
    let openDataTransfer: (String) -> Void
    let openDataGeneration: (String) -> Void
    let openDuplicateTable: (DatabaseTreeTableRef) -> Void
    let openStructure: (DatabaseTreeTableRef) -> Void
    let refreshObjects: (_ database: String, _ schema: String?) -> Void
    let showRoutineDDL: (RoutineInfo) -> Void
    let batchToggleTruncate: ([DatabaseTreeTableRef]) -> Void
    let batchToggleDelete: ([DatabaseTreeTableRef]) -> Void
    var connect: (DatabaseConnection) -> Void = { _ in }
    var disconnect: (DatabaseConnection) -> Void = { _ in }
    var refreshConnection: (DatabaseConnection) -> Void = { _ in }
    var editConnection: (DatabaseConnection) -> Void = { _ in }
    var newQuery: (DatabaseConnection) -> Void = { _ in }
    var newDatabase: (DatabaseConnection) -> Void = { _ in }
    let removeRecent: (DatabaseTreeTableRef) -> Void
    let clearRecents: () -> Void

    @MainActor
    func target(_ scope: DatabaseScope) -> SidebarActionTarget {
        SidebarActionTarget(scope: scope, host: coordinator)
    }

    @MainActor
    func target(for ref: DatabaseTreeTableRef) -> SidebarActionTarget {
        target(DatabaseScope(connectionId: ref.connectionId, database: ref.database, schema: ref.schema))
    }
}

struct DatabaseTreeRowContext {
    let databaseType: DatabaseType
    let defaultDatabase: String?
    let systemSchemas: Set<String>
    let pendingTruncates: Set<DatabaseTreeTableRef>
    let pendingDeletes: Set<DatabaseTreeTableRef>
    var connectionStatus: ConnectionStatus = .disconnected
    var connectFailureMessage: String?
    var isExternalSchema: @MainActor (String, String) -> Bool = { _, _ in false }
    var isDatabaseOpen: @MainActor (String) -> Bool = { _ in true }

    func isPendingTruncate(_ ref: DatabaseTreeTableRef) -> Bool {
        pendingTruncates.contains(ref)
    }

    func isPendingDelete(_ ref: DatabaseTreeTableRef) -> Bool {
        pendingDeletes.contains(ref)
    }
}

struct DatabaseTreeRowView: View {
    let node: DatabaseTreeNode
    let isEmphasized: Bool
    let context: DatabaseTreeRowContext
    let actions: DatabaseTreeRowActions

    private var containerEntityName: String {
        PluginManager.shared.containerEntityName(for: context.databaseType)
    }

    var body: some View {
        if hasContextMenu {
            row.contextMenu { menuItems }
        } else {
            row
        }
    }

    private var row: some View {
        rowContent
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityIdentifier(node.accessibilityIdentifier)
    }

    @ViewBuilder private var rowContent: some View {
        switch node.kind {
        case .recentSection:
            header(
                text: String(localized: "Recent"),
                systemImage: "clock.arrow.circlepath",
                isSystem: false
            )
        case .recentTable(let ref):
            HStack(spacing: 6) {
                TableRow(
                    table: ref.table,
                    isPendingTruncate: context.isPendingTruncate(ref),
                    isPendingDelete: context.isPendingDelete(ref)
                )
                if !ref.database.isEmpty, ref.database != context.defaultDatabase {
                    Text(ref.database)
                        .font(.caption)
                        .foregroundStyle(isEmphasized ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isEmphasized ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        case .connectionRoot:
            header(
                text: String(localized: "My Connections"),
                systemImage: "rectangle.stack",
                isSystem: false
            )
        case .folder(let group):
            ConnectionFolderRowView(group: group, isEmphasized: isEmphasized)
        case .connection(let connection):
            ConnectionRowView(
                connection: connection,
                status: context.connectionStatus,
                isEmphasized: isEmphasized,
                failureMessage: context.connectFailureMessage,
                onRetry: { actions.connect(connection) }
            )
        case .database(_, let metadata):
            let isOpen = context.isDatabaseOpen(metadata.name)
            header(
                text: metadata.name,
                systemImage: Self.databaseSymbol(isSystem: metadata.isSystemDatabase, isOpen: isOpen),
                isSystem: metadata.isSystemDatabase,
                isClosed: !isOpen
            )
            .accessibilityValue(isOpen ? String(localized: "Open") : String(localized: "Closed"))
        case .schema(_, let database, let schema):
            header(
                text: schema,
                systemImage: context.isExternalSchema(database, schema) ? "folder.badge.gearshape" : "folder",
                isSystem: context.systemSchemas.contains(schema),
                caption: context.isExternalSchema(database, schema) ? String(localized: "External") : nil
            )
        case .table(let ref):
            TableRow(
                table: ref.table,
                isPendingTruncate: context.isPendingTruncate(ref),
                isPendingDelete: context.isPendingDelete(ref)
            )
            .foregroundStyle(isEmphasized ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        case .routine(let ref):
            RoutineRowView(routine: ref.routine)
                .foregroundStyle(isEmphasized ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        case .status(let status):
            statusRow(status)
        }
    }

    static func databaseSymbol(isSystem: Bool, isOpen: Bool) -> String {
        if isSystem { return isOpen ? "gearshape.fill" : "gearshape" }
        return isOpen ? "cylinder.fill" : "cylinder"
    }

    private func header(
        text: String,
        systemImage: String,
        isSystem: Bool,
        isClosed: Bool = false,
        caption: String? = nil
    ) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(text)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: systemImage)
        }
        .lineLimit(1)
        .foregroundStyle(foreground(isSystem: isSystem, isClosed: isClosed))
    }

    @ViewBuilder
    private func statusRow(_ status: DatabaseTreeNode.Status) -> some View {
        switch status {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(String(localized: "Loading\u{2026}"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .empty:
            Text(String(localized: "No items"))
                .font(.callout)
                .foregroundStyle(.secondary)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case .disconnected:
            Label(String(localized: "Not connected"), systemImage: "bolt.horizontal.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var hasContextMenu: Bool {
        switch node.kind {
        case .status, .recentSection, .connectionRoot, .folder: return false
        default: return true
        }
    }

    @ViewBuilder private var menuItems: some View {
        switch node.kind {
        case .connectionRoot, .folder, .recentSection:
            EmptyView()
        case .connection(let connection):
            ConnectionNodeContextMenu(
                connection: connection,
                status: context.connectionStatus,
                isReadOnly: actions.isReadOnly,
                canCreateDatabase: PluginManager.shared.supportsContainerSwitching(for: connection.type)
                    && PluginManager.shared.connectionMode(for: connection.type) != .fileBased,
                containerEntityName: PluginManager.shared.containerEntityName(for: connection.type),
                onConnect: { actions.connect(connection) },
                onDisconnect: { actions.disconnect(connection) },
                onRefresh: { actions.refreshConnection(connection) },
                onEdit: { actions.editConnection(connection) },
                onNewQuery: { actions.newQuery(connection) },
                onNewDatabase: { actions.newDatabase(connection) }
            )
        case .recentTable(let ref):
            tableMenu(ref, selected: [ref])
            Divider()
            Button(String(localized: "Remove from Recent")) {
                actions.removeRecent(ref)
            }
            Button(String(localized: "Clear Recent Tables")) {
                actions.clearRecents()
            }
        case .database(let connectionId, let metadata):
            let scope = DatabaseScope(connectionId: connectionId, database: metadata.name, schema: nil)
            let isOpen = context.isDatabaseOpen(metadata.name)
            if !isOpen {
                Button(String(format: String(localized: "Open %@"), containerEntityName)) {
                    actions.openDatabase(metadata.name)
                }
            } else if metadata.name == context.defaultDatabase {
                Button(String(localized: "Close Connection")) {
                    if let connection = connectionForMenu(connectionId) { actions.disconnect(connection) }
                }
            } else {
                Button(String(format: String(localized: "Close %@"), containerEntityName)) {
                    actions.closeDatabase(metadata.name)
                }
            }
            Divider()
            Button(String(localized: "Refresh")) {
                actions.refreshDatabase(metadata.name)
            }
            Divider()
            createObjectItems(scope)
            Divider()
            Button(String(localized: "Data Transfer\u{2026}")) {
                actions.openDataTransfer(metadata.name)
            }
            Button(String(localized: "Generate Data\u{2026}")) {
                actions.openDataGeneration(metadata.name)
            }
            if SidebarContextMenuLogic.dropDatabaseVisible(
                databaseType: context.databaseType,
                metadata: metadata,
                defaultDatabase: context.defaultDatabase
            ) {
                Divider()
                Button(String(format: String(localized: "Drop %@…"), containerEntityName), role: .destructive) {
                    actions.coordinator?.databaseToDrop = scope
                }
                .disabled(actions.isReadOnly)
            }
        case .schema(let connectionId, let database, let schema):
            Button(String(localized: "Refresh")) {
                actions.refreshObjects(database, schema)
            }
            Divider()
            createObjectItems(DatabaseScope(connectionId: connectionId, database: database, schema: schema))
        case .table(let ref):
            tableMenu(ref, selected: actions.selectedRefs(ref.connectionId))
        case .routine(let ref):
            RoutineContextMenu(routine: ref.routine, onShowDDL: actions.showRoutineDDL)
        case .status:
            EmptyView()
        }
    }

    private func tableMenu(_ ref: DatabaseTreeTableRef, selected: Set<DatabaseTreeTableRef>) -> some View {
        SidebarContextMenu(
            clickedRef: ref,
            selectedRefs: selected,
            target: actions.target(for: ref),
            onBatchToggleTruncate: actions.batchToggleTruncate,
            onBatchToggleDelete: actions.batchToggleDelete,
            onOpenStructure: { actions.openStructure(ref) },
            onDuplicateTable: { actions.openDuplicateTable(ref) }
        )
    }

    @ViewBuilder
    private func createObjectItems(_ scope: DatabaseScope) -> some View {
        let isReadOnly = actions.target(scope).isReadOnly
        Button(String(localized: "New Table")) {
            actions.coordinator?.createNewTable(scope: scope)
        }
        .disabled(isReadOnly || actions.coordinator == nil)
        Button(String(localized: "New View")) {
            actions.coordinator?.createView(scope: scope)
        }
        .disabled(isReadOnly || actions.coordinator == nil)
    }

    private func connectionForMenu(_ connectionId: UUID) -> DatabaseConnection? {
        DatabaseManager.shared.session(for: connectionId)?.connection
            ?? ConnectionStorage.shared.loadConnection(id: connectionId)
    }

    private func foreground(isSystem: Bool, isClosed: Bool) -> AnyShapeStyle {
        if isEmphasized { return AnyShapeStyle(.white) }
        if isClosed { return AnyShapeStyle(.tertiary) }
        if isSystem { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(.primary)
    }
}
