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
}

struct SidebarContextMenu: View {
    let clickedTable: TableInfo?
    let selectedTables: Set<TableInfo>
    let isReadOnly: Bool
    let onBatchToggleTruncate: ([String]) -> Void
    let onBatchToggleDelete: ([String]) -> Void
    let coordinator: MainContentCoordinator?
    var activateBeforeAction: (@MainActor () async -> Void)?

    /// The clicked node's own connection type and duplicate action. The tree spans every saved
    /// connection, so neither may be read from the window this menu happens to live in: a node
    /// under another connection would be gated against the wrong dialect and duplicated on the
    /// wrong server.
    var duplicateDatabaseType: DatabaseType?
    var onDuplicateTable: (() -> Void)?

    private var hasSelection: Bool {
        SidebarContextMenuLogic.hasSelection(selectedTables: selectedTables, clickedTable: clickedTable)
    }

    private var isView: Bool {
        SidebarContextMenuLogic.isView(clickedTable: clickedTable)
    }

    private var effectiveTableNames: [String] {
        if selectedTables.isEmpty, let table = clickedTable {
            return [table.name]
        }
        return selectedTables.map(\.name).sorted()
    }

    @MainActor
    private func perform(_ action: @MainActor @escaping () -> Void) {
        guard let activate = activateBeforeAction else {
            action()
            return
        }
        Task { @MainActor in
            await activate()
            action()
        }
    }

    var body: some View {
        Button("Create New View...") {
            perform { coordinator?.createView() }
        }
        .disabled(isReadOnly)

        Divider()

        if clickedTable != nil {
            if isView {
                Button("Edit View Definition") {
                    perform {
                        if let viewName = clickedTable?.name {
                            coordinator?.editViewDefinition(viewName)
                        }
                    }
                }
                .disabled(isReadOnly)
            }

            Button("Show Structure") {
                perform {
                    if let clickedTable {
                        coordinator?.openTableTab(clickedTable, showStructure: true, activateGridFocus: true)
                    }
                }
            }

            if let duplicateDatabaseType, let onDuplicateTable,
               SidebarContextMenuLogic.duplicateVisible(
                   clickedTable: clickedTable,
                   databaseType: duplicateDatabaseType
               ) {
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
        }

        Button("View ER Diagram") {
            perform { coordinator?.showERDiagram() }
        }

        if hasSelection {
            Button("Copy Name") {
                ClipboardService.shared.writeText(effectiveTableNames.joined(separator: ","))
            }

            Button("Export...") {
                perform { coordinator?.openExportDialog(preselectedTableNames: Set(effectiveTableNames)) }
            }
        }

        if SidebarContextMenuLogic.importVisible(
            clickedTable: clickedTable,
            supportsImport: PluginManager.shared.supportsImport(
                for: coordinator?.connection.type ?? .mysql
            )
        ) {
            ImportMenuItems(
                formats: PluginManager.shared.importFormatOptions(for: coordinator?.connection.type ?? .mysql),
                isDisabled: isReadOnly,
                shortcut: nil,
                action: { formatId in perform { coordinator?.openImportDialog(formatId: formatId) } }
            )
        }

        let maintenanceOps = coordinator?.supportedMaintenanceOperations() ?? []
        if SidebarContextMenuLogic.maintenanceGroupEnabled(
            isReadOnly: isReadOnly,
            hasSelection: hasSelection,
            supportedOperations: maintenanceOps
        ) {
            Menu(String(localized: "Maintenance")) {
                ForEach(maintenanceOps, id: \.self) { op in
                    Button(op) {
                        perform {
                            if let table = clickedTable?.name {
                                coordinator?.showMaintenanceSheet(operation: op, tableName: table)
                            }
                        }
                    }
                }
            }
        }

        if hasSelection {
            Divider()

            if SidebarContextMenuLogic.truncateVisible(clickedTable: clickedTable) {
                Button("Truncate") {
                    perform { onBatchToggleTruncate(effectiveTableNames) }
                }
                .disabled(isReadOnly)
            }

            Button(
                SidebarContextMenuLogic.deleteLabel(for: clickedTable?.type),
                role: .destructive
            ) {
                perform { onBatchToggleDelete(effectiveTableNames) }
            }
            .disabled(isReadOnly)
        }
    }
}
