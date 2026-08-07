//
//  DatabaseTreeRowView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

struct DatabaseTreeRowActions {
    let coordinator: MainContentCoordinator?
    let isReadOnly: Bool
    let selectedTables: (UUID) -> Set<TableInfo>
    let activate: (DatabaseTreeTableRef) async -> Void
    let setActiveDatabase: (String) -> Void
    let setActiveSchema: (_ database: String, _ schema: String) -> Void
    let refreshDatabase: (String) -> Void
    let refreshObjects: (_ database: String, _ schema: String?) -> Void
    let showRoutineDDL: (RoutineInfo) -> Void
    let batchToggleTruncate: (_ connectionId: UUID, _ tableNames: [String]) -> Void
    let batchToggleDelete: (_ connectionId: UUID, _ tableNames: [String]) -> Void
    let removeRecent: (DatabaseTreeTableRef) -> Void
    let clearRecents: () -> Void
}

struct DatabaseTreeRowContext {
    let databaseType: DatabaseType
    let activeDatabase: String?
    let activeSchema: String?
    let systemSchemas: Set<String>
    let pendingTruncates: [UUID: Set<String>]
    let pendingDeletes: [UUID: Set<String>]
    var isExternalSchema: @MainActor (String, String) -> Bool = { _, _ in false }

    func isPendingTruncate(_ ref: DatabaseTreeTableRef) -> Bool {
        pendingTruncates[ref.connectionId]?.contains(ref.table.name) ?? false
    }

    func isPendingDelete(_ ref: DatabaseTreeTableRef) -> Bool {
        pendingDeletes[ref.connectionId]?.contains(ref.table.name) ?? false
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

    private var schemaEntityName: String {
        PluginManager.shared.schemaEntityName(for: context.databaseType)
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
    }

    @ViewBuilder
    private var rowContent: some View {
        switch node.kind {
        case .recentSection:
            header(
                text: String(localized: "Recent"),
                systemImage: "clock.arrow.circlepath",
                isActive: false,
                isSystem: false
            )
        case .recentTable(let ref):
            TableRow(
                table: ref.table,
                isPendingTruncate: context.isPendingTruncate(ref),
                isPendingDelete: context.isPendingDelete(ref)
            )
            .foregroundStyle(isEmphasized ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        case .connectionRoot, .folder, .connection:
            EmptyView()
        case .database(_, let metadata):
            header(
                text: metadata.name,
                systemImage: metadata.isSystemDatabase ? "gearshape" : "cylinder",
                isActive: metadata.name == context.activeDatabase,
                isSystem: metadata.isSystemDatabase
            )
        case .schema(_, let database, let schema):
            header(
                text: schema,
                systemImage: context.isExternalSchema(database, schema) ? "folder.badge.gearshape" : "folder",
                isActive: database == context.activeDatabase && schema == context.activeSchema,
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

    private func header(
        text: String,
        systemImage: String,
        isActive: Bool,
        isSystem: Bool,
        caption: String? = nil
    ) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(text)
                    .fontWeight(isActive ? .bold : .regular)
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
        .foregroundStyle(foreground(isActive: isActive, isSystem: isSystem))
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
        }
    }

    private var hasContextMenu: Bool {
        switch node.kind {
        case .status, .recentSection: return false
        default: return true
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        switch node.kind {
        case .connectionRoot, .folder, .connection, .recentSection:
            EmptyView()
        case .recentTable(let ref):
            SidebarContextMenu(
                clickedTable: ref.table,
                selectedTables: [ref.table],
                isReadOnly: actions.isReadOnly,
                onBatchToggleTruncate: { actions.batchToggleTruncate(ref.connectionId, $0) },
                onBatchToggleDelete: { actions.batchToggleDelete(ref.connectionId, $0) },
                coordinator: actions.coordinator,
                activateBeforeAction: { await actions.activate(ref) }
            )
            Divider()
            Button(String(localized: "Remove from Recent")) {
                actions.removeRecent(ref)
            }
            Button(String(localized: "Clear Recent Tables")) {
                actions.clearRecents()
            }
        case .database(_, let metadata):
            Button(String(format: String(localized: "Use as Active %@"), containerEntityName)) {
                actions.setActiveDatabase(metadata.name)
            }
            .disabled(metadata.name == context.activeDatabase)
            Button(String(localized: "Refresh")) {
                actions.refreshDatabase(metadata.name)
            }
        case .schema(_, let database, let schema):
            Button(String(format: String(localized: "Use as Active %@"), schemaEntityName)) {
                actions.setActiveSchema(database, schema)
            }
            .disabled(database == context.activeDatabase && schema == context.activeSchema)
            Button(String(localized: "Refresh")) {
                actions.refreshObjects(database, schema)
            }
        case .table(let ref):
            SidebarContextMenu(
                clickedTable: ref.table,
                selectedTables: actions.selectedTables(ref.connectionId),
                isReadOnly: actions.isReadOnly,
                onBatchToggleTruncate: { actions.batchToggleTruncate(ref.connectionId, $0) },
                onBatchToggleDelete: { actions.batchToggleDelete(ref.connectionId, $0) },
                coordinator: actions.coordinator,
                activateBeforeAction: { await actions.activate(ref) }
            )
        case .routine(let ref):
            RoutineContextMenu(routine: ref.routine, onShowDDL: actions.showRoutineDDL)
        case .status:
            EmptyView()
        }
    }

    private func foreground(isActive: Bool, isSystem: Bool) -> AnyShapeStyle {
        if isEmphasized { return AnyShapeStyle(.white) }
        if isActive { return AnyShapeStyle(.tint) }
        if isSystem { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(.primary)
    }
}
