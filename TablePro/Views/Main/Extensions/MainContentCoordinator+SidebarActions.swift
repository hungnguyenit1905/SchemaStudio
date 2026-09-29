//
//  MainContentCoordinator+SidebarActions.swift
//  TablePro
//
//  Sidebar context menu actions for MainContentCoordinator.
//

import AppKit
import Foundation
import TableProPluginKit
import UniformTypeIdentifiers

extension MainContentCoordinator {
    // MARK: - Result Set Operations

    var canPinActiveResultSet: Bool {
        guard let tab = tabManager.selectedTab else { return false }
        return ResultTabBarPolicy.canPin(tabType: tab.tabType, display: tab.display)
    }

    var isActiveResultSetPinned: Bool {
        tabManager.selectedTab?.display.activeResultSet?.isPinned == true
    }

    func togglePinResultSet(id: UUID) {
        guard let tabIdx = tabManager.selectedTabIndex else { return }
        tabManager.mutate(at: tabIdx) { $0.display.togglePin(resultSetId: id) }
    }

    func closeResultSet(id: UUID) {
        guard let tabIdx = tabManager.selectedTabIndex else { return }
        let rs = tabManager.tabs[tabIdx].display.resultSets.first { $0.id == id }
        guard rs?.isPinned != true else { return }
        let tabId = tabManager.tabs[tabIdx].id
        tabManager.mutate(at: tabIdx) { $0.display.resultSets.removeAll { $0.id == id } }
        if tabManager.tabs[tabIdx].display.activeResultSetId == id {
            let newActiveId = tabManager.tabs[tabIdx].display.resultSets.last?.id
            switchActiveResultSet(to: newActiveId, in: tabId)
        }
        if tabManager.tabs[tabIdx].display.resultSets.isEmpty {
            setActiveTableRows(TableRows(), for: tabId)
            tabManager.mutate(at: tabIdx) { tab in
                tab.execution.errorMessage = nil
                tab.execution.rowsAffected = 0
                tab.execution.executionTime = nil
                tab.execution.statusMessage = nil
                tab.schemaVersion += 1
                tab.display.isResultsCollapsed = true
            }
            toolbarState.isResultsCollapsed = true
        }
    }

    var canClearActiveQueryResults: Bool {
        guard let tab = tabManager.selectedTab, tab.tabType == .query else { return false }
        return !tabSessionRegistry.tableRows(for: tab.id).rows.isEmpty || tab.execution.lastExecutedAt != nil
    }

    func clearActiveQueryResults() {
        guard let tabIdx = tabManager.selectedTabIndex else { return }
        let tabId = tabManager.tabs[tabIdx].id

        if let lastPinned = tabManager.tabs[tabIdx].display.resultSets.last(where: \.isPinned) {
            switchActiveResultSet(to: lastPinned.id, in: tabId)
            tabManager.mutate(at: tabIdx) { $0.display.removeUnpinnedResults() }
            return
        }

        setActiveTableRows(TableRows(), for: tabId)
        tabManager.mutate(at: tabIdx) { tab in
            tab.display.removeUnpinnedResults()
            tab.execution.errorMessage = nil
            tab.execution.rowsAffected = 0
            tab.execution.executionTime = nil
            tab.execution.statusMessage = nil
            tab.execution.lastExecutedAt = nil
            tab.schemaVersion += 1
            tab.display.isResultsCollapsed = true
        }
        toolbarState.isResultsCollapsed = true
    }

    // MARK: - Table Operations

    func createNewTable(scope: DatabaseScope) {
        guard !SidebarActionTarget(scope: scope, host: self).isReadOnly else { return }

        if scope.connectionId == connectionId, tabManager.tabs.isEmpty {
            tabManager.addCreateTableTab(databaseName: scope.database, schemaName: scope.schema)
            return
        }
        let payload = EditorTabPayload(
            connectionId: scope.connectionId,
            tabType: .createTable,
            databaseName: scope.database,
            schemaName: scope.schema
        )
        openTabInCurrentWindow(payload)
    }

    // MARK: - View Operations

    func createView(scope: DatabaseScope) {
        guard !SidebarActionTarget(scope: scope, host: self).isReadOnly else { return }

        let driver = DatabaseManager.shared.driver(for: scope.connectionId)
        let template = driver?.createViewTemplate()
            ?? "CREATE VIEW view_name AS\nSELECT column1, column2\nFROM table_name\nWHERE condition;"

        let payload = EditorTabPayload(
            connectionId: scope.connectionId,
            tabType: .query,
            databaseName: scope.database,
            schemaName: scope.schema,
            initialQuery: template
        )
        openTabInCurrentWindow(payload)
    }

    func editViewDefinition(_ viewName: String, scope: DatabaseScope) {
        Task {
            let manager = DatabaseManager.shared
            let query: String
            do {
                query = try await manager.withScopedDriver(
                    scope: scope,
                    route: manager.metadataRoute(for: scope)
                ) { driver in
                    try await driver.fetchViewDefinition(view: viewName)
                }
            } catch {
                let driver = manager.driver(for: scope.connectionId)
                let template = driver?.editViewFallbackTemplate(viewName: viewName)
                    ?? "CREATE OR REPLACE VIEW \(viewName) AS\nSELECT * FROM table_name;"
                query = "-- Could not fetch view definition: \(error.localizedDescription)\n\(template)"
            }
            let payload = EditorTabPayload(
                connectionId: scope.connectionId,
                tabType: .query,
                databaseName: scope.database,
                schemaName: scope.schema,
                initialQuery: query
            )
            self.openTabInCurrentWindow(payload)
        }
    }

    // MARK: - Export/Import

    func openExportDialog(preselectedTableNames: Set<String>? = nil, scope: DatabaseScope) {
        exportPreselectedTableNames = preselectedTableNames
        exportScope = scope
        activeSheet = .exportDialog
    }

    /// The wizard picks its own source and target, so the scope only
    /// prefills the first step. It comes from the clicked node, which can
    /// belong to a different connection than this window.
    func openDataTransferWizard(preselectedScope: DatabaseScope? = nil) {
        dataTransferPreselectedScope = preselectedScope
        activeSheet = .dataTransfer
    }

    func openDataGenerationWizard(preselectedScope: DatabaseScope? = nil) {
        dataGenerationPreselectedScope = preselectedScope
        activeSheet = .dataGeneration
    }

    /// The scope comes from the clicked node, not from this window: the tree spans every saved
    /// connection, so the duplicate has to run on the connection and database the user right
    /// clicked. Safe mode and the execution gate are resolved against that same connection, the
    /// first by the menu item's own read-only state and the second when the run is authorized.
    func openDuplicateTableSheet(_ table: TableInfo, scope: DatabaseScope) {
        activeSheet = .duplicateTable(scope: scope, table: table.name)
    }

    /// Refresh first, open second: the tree has to know the new table exists before a tab asks
    /// it for the table's columns. A node under another connection never routes through this
    /// window's coordinator, which would bind the tab to the wrong connection.
    func finishDuplicate(_ result: DuplicateResult, scope: DatabaseScope) {
        Task { [weak self] in
            guard let self else { return }
            guard scope.connectionId == self.connectionId else {
                await self.refreshDuplicateSource(scope)
                self.openDuplicatedTableInNodeConnection(result, scope: scope)
                return
            }
            await self.refreshTables(currentDatabaseOnly: true)
            self.openTableTab(result.target.name, schema: result.target.schema)
        }
    }

    private func refreshDuplicateSource(_ scope: DatabaseScope) async {
        guard let connection = services.databaseManager.session(for: scope.connectionId)?.connection else { return }
        await services.schemaRefreshService.refresh(connection: connection, database: scope.database)
    }

    private func openDuplicatedTableInNodeConnection(_ result: DuplicateResult, scope: DatabaseScope) {
        let payload = EditorTabPayload(
            connectionId: scope.connectionId,
            tabType: .table,
            tableName: result.target.name,
            databaseName: scope.database,
            schemaName: result.target.schema
        )
        openTabInCurrentWindow(payload)
    }

    /// A snapshot taken while rows are still being replaced resolves to real-but-wrong rows,
    /// because `RowID` is positional.
    func openExportQueryResultsDialog() {
        guard let tab = tabManager.selectedTab,
              !tab.execution.isExecuting,
              !tab.pagination.isLoadingMore,
              !tabSessionRegistry.tableRows(for: tab.id).rows.isEmpty else { return }
        activeSheet = .exportQueryResults
    }

    func openImportDialog(formatId: String, scope: DatabaseScope) {
        let target = SidebarActionTarget(scope: scope, host: self)
        guard !target.isReadOnly, let databaseType = target.databaseType else { return }
        guard PluginManager.shared.supportsImport(for: databaseType) else {
            AlertHelper.showErrorSheet(
                title: String(localized: "Import Not Supported"),
                message: String(
                    format: String(localized: "Import is not supported for %@ connections."),
                    databaseType.rawValue
                ),
                window: nil
            )
            return
        }
        guard let plugin = PluginManager.shared.importPlugin(forFormat: formatId) else { return }
        let pluginType = type(of: plugin)

        let panel = NSOpenPanel()
        var contentTypes: [UTType] = []
        for ext in pluginType.acceptedFileExtensions {
            if let utType = UTType(filenameExtension: ext) {
                contentTypes.append(utType)
            }
        }
        if !pluginType.requiresTargetTable, let gzType = UTType(filenameExtension: "gz") {
            contentTypes.append(gzType)
        }
        if !contentTypes.isEmpty {
            panel.allowedContentTypes = contentTypes
        }
        panel.allowsMultipleSelection = false
        panel.message = String(format: String(localized: "Select %@ file to import"), pluginType.formatDisplayName)

        guard let window = contentWindow else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.importFileURL = url
            self?.importScope = scope
            switch ImportRouting.route(formatId: formatId, requiresTargetTable: pluginType.requiresTargetTable) {
            case .statement(let id): self?.activeSheet = .importDialog(formatId: id)
            case .rowMapping(let id): self?.activeSheet = .rowImport(formatId: id)
            }
        }
    }

    // MARK: - Maintenance

    func supportedMaintenanceOperations(for connectionId: UUID) -> [String] {
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return [] }
        return driver.supportedMaintenanceOperations() ?? []
    }

    func showMaintenanceSheet(operation: String, tableName: String, scope: DatabaseScope) {
        activeSheet = .maintenance(operation: operation, tableName: tableName, scope: scope)
    }

    func executeMaintenance(
        operation: String,
        tableName: String,
        options: [String: String],
        scope: DatabaseScope
    ) {
        let manager = DatabaseManager.shared
        guard let driver = manager.driver(for: scope.connectionId),
              let databaseType = manager.session(for: scope.connectionId)?.connection.type else { return }
        guard let statements = driver.maintenanceStatements(
            operation: operation, table: tableName, options: options
        ) else { return }

        Task { [weak self] in
            guard let self else { return }
            let decision = await ExecutionGateProvider.shared.authorize(
                OperationRequest(
                    connectionId: scope.connectionId,
                    databaseType: databaseType,
                    sql: statements.joined(separator: "\n"),
                    kind: .maintenance,
                    caller: .userInterface,
                    capabilities: .interactiveUser,
                    operationDescription: operation
                )
            )
            guard case .authorized = decision else {
                if let reason = decision.deniedReason {
                    await AlertHelper.showErrorSheet(
                        title: String(format: String(localized: "%@ failed"), operation),
                        message: reason,
                        window: self.contentWindow
                    )
                }
                return
            }
            do {
                let lastResult = try await manager.withScopedDriver(
                    scope: scope,
                    route: manager.executionRoute(for: scope),
                    tracksCancellation: true
                ) { driver -> QueryResult? in
                    var lastResult: QueryResult?
                    for sql in statements {
                        lastResult = try await driver.execute(query: sql)
                    }
                    return lastResult
                }
                await AlertHelper.showInfoSheet(
                    title: String(format: String(localized: "%@ completed"), operation),
                    message: lastResult?.statusMessage
                        ?? String(format: String(localized: "%@ on %@ completed successfully."), operation, tableName),
                    window: self.contentWindow
                )
            } catch {
                await AlertHelper.showErrorSheet(
                    title: String(format: String(localized: "%@ failed"), operation),
                    message: error.localizedDescription,
                    window: self.contentWindow
                )
            }
        }
    }
}
