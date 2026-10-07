//
//  SidebarContextMenu.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

enum SidebarContextMenuLogic {
    static func hasSelection(selectedTables: Set<TableInfo>, clickedTable: TableInfo?) -> Bool {
        !selectedTables.isEmpty || clickedTable != nil
    }

    static func isView(clickedTable: TableInfo?) -> Bool {
        clickedTable?.type == .view
    }

    static func isReadOnlyKind(_ type: TableInfo.TableType?) -> Bool {
        switch type {
        case .view, .materializedView, .foreignTable, .systemTable, .externalTable:
            return true
        case .table, .partitionedTable, .none:
            return false
        }
    }

    static func importVisible(clickedTable: TableInfo?, supportsImport: Bool) -> Bool {
        guard supportsImport else { return false }
        return !isReadOnlyKind(clickedTable?.type)
    }

    /// The item is offered for a real table on a vendor that has a duplicate plan builder. A type
    /// without one is refused here rather than at the server, and phase-by-phase vendor support
    /// follows the builder registry on its own.
    static func duplicateVisible(clickedTable: TableInfo?, databaseType: DatabaseType) -> Bool {
        guard let clickedTable, !isReadOnlyKind(clickedTable.type) else { return false }
        return DuplicatePlanBuilder.builder(for: databaseType) != nil
    }

    /// Duplicating a batch needs its own progress and rollback story, so a multi-selection
    /// disables the item instead of quietly duplicating the row that happened to be clicked.
    static func duplicateEnabled(clickedTable: TableInfo?, selectedTables: Set<TableInfo>) -> Bool {
        guard clickedTable != nil else { return false }
        return selectedTables.count <= 1
    }

    static func truncateVisible(clickedTable: TableInfo?) -> Bool {
        !isReadOnlyKind(clickedTable?.type)
    }

    static func deleteLabel(for type: TableInfo.TableType?) -> String {
        switch type {
        case .view: return String(localized: "Drop View")
        case .materializedView: return String(localized: "Drop Materialized View")
        case .foreignTable: return String(localized: "Drop Foreign Table")
        case .systemTable: return String(localized: "Drop")
        case .externalTable: return String(localized: "Drop External Table")
        case .table, .partitionedTable, .none: return String(localized: "Delete")
        }
    }

    static func maintenanceGroupEnabled(
        isReadOnly: Bool,
        hasSelection: Bool,
        supportedOperations: [String]
    ) -> Bool {
        guard !isReadOnly, hasSelection else { return false }
        return !supportedOperations.isEmpty
    }

    @MainActor
    static func dropDatabaseVisible(
        databaseType: DatabaseType,
        metadata: DatabaseMetadata,
        defaultDatabase: String?
    ) -> Bool {
        guard PluginManager.shared.supportsDropDatabase(for: databaseType) else { return false }
        guard !metadata.isSystemDatabase else { return false }
        guard metadata.name != defaultDatabase else { return false }
        return true
    }

    static func tablesInScope(
        of clicked: DatabaseTreeTableRef,
        selected: Set<DatabaseTreeTableRef>
    ) -> [DatabaseTreeTableRef] {
        guard selected.contains(clicked) else { return [clicked] }
        return selected
            .filter { $0.connectionId == clicked.connectionId && $0.database == clicked.database }
            .sorted { $0.id < $1.id }
    }
}

struct SidebarContextMenu: View {
    let clickedRef: DatabaseTreeTableRef
    let selectedRefs: Set<DatabaseTreeTableRef>
    let target: SidebarActionTarget
    let onBatchToggleTruncate: ([DatabaseTreeTableRef]) -> Void
    let onBatchToggleDelete: ([DatabaseTreeTableRef]) -> Void
    let onOpenStructure: () -> Void
    var onDuplicateTable: (() -> Void)?

    private var clickedTable: TableInfo? { clickedRef.table }

    private var actedOn: [DatabaseTreeTableRef] {
        SidebarContextMenuLogic.tablesInScope(of: clickedRef, selected: selectedRefs)
    }

    private var selectedTables: Set<TableInfo> {
        Set(actedOn.map(\.table))
    }

    private var isReadOnly: Bool { target.isReadOnly }

    private var databaseType: DatabaseType { target.databaseType ?? .mysql }

    private var scope: DatabaseScope { target.scope }

    private var host: MainContentCoordinator? { target.coordinator }

    private var hasSelection: Bool {
        SidebarContextMenuLogic.hasSelection(selectedTables: selectedTables, clickedTable: clickedTable)
    }

    private var isView: Bool {
        SidebarContextMenuLogic.isView(clickedTable: clickedTable)
    }

    private var effectiveTableNames: [String] {
        actedOn.map(\.table.name)
    }

    var body: some View {
        Button("Create New View...") {
            host?.createView(scope: scope)
        }
        .disabled(isReadOnly)

        Divider()

        if isView {
            Button("Edit View Definition") {
                host?.editViewDefinition(clickedRef.table.name, scope: scope)
            }
            .disabled(isReadOnly)
        }

        Button("Show Structure") {
            onOpenStructure()
        }

        if let onDuplicateTable,
           SidebarContextMenuLogic.duplicateVisible(clickedTable: clickedTable, databaseType: databaseType) {
            let canDuplicate = SidebarContextMenuLogic.duplicateEnabled(
                clickedTable: clickedTable,
                selectedTables: selectedTables
            )
            Button("Duplicate Table...") {
                onDuplicateTable()
            }
            .disabled(isReadOnly || !canDuplicate)
            .help(
                canDuplicate
                    ? String(localized: "Copy this table's structure, and its rows if you ask for them.")
                    : String(localized: "Select a single table to duplicate.")
            )
        }

        Button("View ER Diagram") {
            host?.showERDiagram(scope: scope)
        }

        if hasSelection {
            Button("Copy Name") {
                ClipboardService.shared.writeText(effectiveTableNames.joined(separator: ","))
            }

            Button("Export...") {
                host?.openExportDialog(preselectedTableNames: Set(effectiveTableNames), scope: scope)
            }
        }

        if SidebarContextMenuLogic.importVisible(
            clickedTable: clickedTable,
            supportsImport: PluginManager.shared.supportsImport(for: databaseType)
        ) {
            ImportMenuItems(
                formats: PluginManager.shared.importFormatOptions(for: databaseType),
                isDisabled: isReadOnly,
                shortcut: nil,
                action: { formatId in host?.openImportDialog(formatId: formatId, scope: scope) }
            )
        }

        let maintenanceOps = host?.supportedMaintenanceOperations(for: scope.connectionId) ?? []
        if SidebarContextMenuLogic.maintenanceGroupEnabled(
            isReadOnly: isReadOnly,
            hasSelection: hasSelection,
            supportedOperations: maintenanceOps
        ) {
            Menu(String(localized: "Maintenance")) {
                ForEach(maintenanceOps, id: \.self) { op in
                    Button(op) {
                        host?.showMaintenanceSheet(operation: op, tableName: clickedRef.table.name, scope: scope)
                    }
                }
            }
        }

        if hasSelection {
            Divider()

            if SidebarContextMenuLogic.truncateVisible(clickedTable: clickedTable) {
                Button("Truncate") {
                    onBatchToggleTruncate(actedOn)
                }
                .disabled(isReadOnly)
            }

            Button(
                SidebarContextMenuLogic.deleteLabel(for: clickedTable?.type),
                role: .destructive
            ) {
                onBatchToggleDelete(actedOn)
            }
            .disabled(isReadOnly)
        }
    }
}
