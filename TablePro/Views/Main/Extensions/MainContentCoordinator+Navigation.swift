//
//  MainContentCoordinator+Navigation.swift
//  TablePro
//
//  Table tab opening and database switching operations for MainContentCoordinator
//

import AppKit
import Foundation
import os
import TableProPluginKit

private let navigationLogger = Logger(subsystem: "com.SchemaStudio", category: "MainContentCoordinator+Navigation")

extension MainContentCoordinator {
    func openTabInCurrentWindow(_ payload: EditorTabPayload, anchor: NSWindow? = nil) {
        guard let anchor = anchor ?? contentWindow else { return }
        openTabRequest(payload, .shared, anchor)
    }

    // MARK: - Table Tab Opening

    func openTableTab(
        _ table: TableInfo,
        schema: String? = nil,
        showStructure: Bool = false,
        forceNonPreview: Bool = false,
        activateGridFocus: Bool = false,
        forceNewTab: Bool = false
    ) {
        openTableTab(
            table.name,
            schema: schema ?? table.schema,
            showStructure: showStructure,
            isView: !table.type.allowsRowEditing,
            forceNonPreview: forceNonPreview,
            activateGridFocus: activateGridFocus,
            forceNewTab: forceNewTab
        )
    }

    func openTableTab(
        _ tableName: String,
        schema: String? = nil,
        showStructure: Bool = false,
        isView: Bool = false,
        forceNonPreview: Bool = false,
        activateGridFocus: Bool = false,
        forceNewTab: Bool = false
    ) {
        let navigationModel = PluginMetadataRegistry.shared.snapshot(
            forTypeId: connection.type.pluginTypeId
        )?.navigationModel ?? .standard

        let currentDatabase: String
        if navigationModel == .inPlace {
            guard tableName.hasPrefix("db"), Int(String(tableName.dropFirst(2))) != nil else {
                return
            }
            currentDatabase = String(tableName.dropFirst(2))
        } else {
            currentDatabase = selectedTabScope?.database ?? browseDatabaseName
        }

        openTableTab(
            tableName,
            database: currentDatabase,
            schema: schema,
            navigationModel: navigationModel,
            showStructure: showStructure,
            isView: isView,
            forceNonPreview: forceNonPreview,
            activateGridFocus: activateGridFocus,
            forceNewTab: forceNewTab
        )
    }

    func openTableTab(
        _ table: TableInfo,
        scope: DatabaseScope,
        showStructure: Bool = false,
        forceNonPreview: Bool = false,
        activateGridFocus: Bool = false,
        forceNewTab: Bool = false
    ) {
        let navigationModel = PluginMetadataRegistry.shared.snapshot(
            forTypeId: connection.type.pluginTypeId
        )?.navigationModel ?? .standard
        guard navigationModel != .inPlace else {
            openTableTab(
                table,
                schema: scope.schema,
                showStructure: showStructure,
                forceNonPreview: forceNonPreview,
                activateGridFocus: activateGridFocus,
                forceNewTab: forceNewTab
            )
            return
        }
        openTableTab(
            table.name,
            database: scope.database,
            schema: scope.schema ?? table.schema,
            navigationModel: navigationModel,
            showStructure: showStructure,
            isView: !table.type.allowsRowEditing,
            forceNonPreview: forceNonPreview,
            activateGridFocus: activateGridFocus,
            forceNewTab: forceNewTab
        )
    }

    private func openTableTab(
        _ tableName: String,
        database currentDatabase: String,
        schema: String?,
        navigationModel: NavigationModel,
        showStructure: Bool,
        isView: Bool,
        forceNonPreview: Bool,
        activateGridFocus: Bool,
        forceNewTab: Bool
    ) {
        let resolvedSchema = DatabaseManager.shared.resolvedSchemaName(schema, for: connectionId)
        let createAsPreview = !forceNonPreview && !forceNewTab
            && AppSettingsManager.shared.tabs.enablePreviewTabs

        if !forceNewTab, activateIfAlreadyOpen(
            tableName: tableName,
            databaseName: currentDatabase,
            schemaName: resolvedSchema,
            showStructure: showStructure,
            activateGridFocus: activateGridFocus,
            includeSiblings: navigationModel != .inPlace
        ) {
            return
        }

        if activateGridFocus {
            pendingGridFocusOnOpen = true
        }

        // During database switch, update the existing tab in-place instead of
        // opening a new native window tab.
        if case .loading = SchemaService.shared.state(for: connectionId) {
            if tabManager.tabs.isEmpty {
                do {
                    try tabManager.addTableTab(
                        tableName: tableName,
                        databaseType: connection.type,
                        databaseName: currentDatabase,
                        schemaName: resolvedSchema,
                        isView: isView
                    )
                } catch {
                    navigationLogger
                        .error("openTableTab addTableTab failed: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                pendingGridFocusOnOpen = false
            }
            return
        }

        if tabManager.tabs.isEmpty {
            addFirstTableTab(
                tableName: tableName,
                currentDatabase: currentDatabase,
                resolvedSchema: resolvedSchema,
                isView: isView,
                createAsPreview: createAsPreview,
                isInPlace: navigationModel == .inPlace
            )
            return
        }

        // In-place navigation: replace current tab content rather than
        // opening new native window tabs (e.g. Redis database switching).
        if navigationModel == .inPlace {
            if let oldTab = tabManager.selectedTab, let oldTableName = oldTab.tableContext.tableName {
                saveLastFilters(for: oldTableName)
            }
            do {
                let replaced = try tabManager.replaceTabContent(
                    tableName: tableName,
                    databaseType: connection.type,
                    databaseName: currentDatabase,
                    schemaName: resolvedSchema
                )
                if replaced {
                    clearFilterState()
                    if let (tab, tabIndex) = tabManager.selectedTabAndIndex {
                        setActiveTableRows(TableRows(), for: tab.id)
                        tabManager.mutate(at: tabIndex) { $0.pagination.reset() }
                        toolbarState.isTableTab = true
                    }
                    restoreLastHiddenColumnsForTable()
                    restoreFiltersForTable(tableName)
                    if let dbIndex = Int(currentDatabase) {
                        selectRedisDatabaseAndQuery(dbIndex)
                    }
                }
            } catch {
                navigationLogger
                    .error("openTableTab replaceTabContent failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }

        if isActiveTabReusable, !forceNewTab {
            reuseActiveTab(
                for: tableName,
                currentDatabase: currentDatabase,
                resolvedSchema: resolvedSchema,
                isView: isView,
                showStructure: showStructure,
                createAsPreview: createAsPreview
            )
            return
        }

        promotePreviewTab()
        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .table,
            tableName: tableName,
            databaseName: currentDatabase,
            schemaName: resolvedSchema,
            isView: isView,
            showStructure: showStructure,
            isPreview: createAsPreview
        )
        openTabInCurrentWindow(payload)
    }

    func activateIfAlreadyOpen(
        tableName: String,
        databaseName: String,
        schemaName: String?,
        showStructure: Bool,
        activateGridFocus: Bool,
        includeSiblings: Bool
    ) -> Bool {
        func matches(_ tab: QueryTab) -> Bool {
            tab.tabType == .table
                && tab.tableContext.tableName == tableName
                && tab.tableContext.databaseName == databaseName
                && tab.tableContext.schemaName == schemaName
        }

        if let match = tabManager.tabs.first(where: matches) {
            if tabManager.selectedTabId != match.id {
                tabManager.selectedTabId = match.id
            }
            applyStructureMode(showStructure, toTab: match.id, in: tabManager)
            if activateGridFocus {
                requestGridFocus()
            }
            return true
        }

        guard includeSiblings else { return false }

        for sibling in MainContentCoordinator.allActiveCoordinators()
            where sibling !== self && sibling.connectionId == connectionId {
            guard let match = sibling.tabManager.tabs.first(where: matches) else { continue }
            sibling.pendingGridFocusOnOpen = activateGridFocus
            applyStructureMode(showStructure, toTab: match.id, in: sibling.tabManager)
            sibling.selectTabAndFocusWindow(match.id)
            return true
        }
        return false
    }

    private func applyStructureMode(_ showStructure: Bool, toTab tabId: UUID, in tabManager: QueryTabManager) {
        guard showStructure, let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tabManager.mutate(at: index) { $0.display.resultsViewMode = .structure }
    }

    private func addFirstTableTab(
        tableName: String,
        currentDatabase: String,
        resolvedSchema: String?,
        isView: Bool,
        createAsPreview: Bool,
        isInPlace: Bool
    ) {
        do {
            if createAsPreview {
                try tabManager.addPreviewTableTab(
                    tableName: tableName,
                    databaseType: connection.type,
                    databaseName: currentDatabase,
                    schemaName: resolvedSchema,
                    isView: isView
                )
            } else {
                try tabManager.addTableTab(
                    tableName: tableName,
                    databaseType: connection.type,
                    databaseName: currentDatabase,
                    schemaName: resolvedSchema,
                    isView: isView
                )
            }
        } catch {
            navigationLogger.error("openTableTab tab creation failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        if let (_, tabIndex) = tabManager.selectedTabAndIndex {
            tabManager.mutate(at: tabIndex) { tab in
                tab.tableContext.isView = isView
                tab.tableContext.isEditable = !isView
                tab.tableContext.schemaName = resolvedSchema
                tab.pagination.reset()
            }
            toolbarState.isTableTab = true
        }
        restoreLastHiddenColumnsForTable()
        restoreFiltersForTable(tableName)
        if isInPlace, let dbIndex = Int(currentDatabase) {
            selectRedisDatabaseAndQuery(dbIndex)
        } else {
            lazyLoadCurrentTabIfNeeded()
        }
    }

    private func reuseActiveTab(
        for tableName: String,
        currentDatabase: String,
        resolvedSchema: String?,
        isView: Bool,
        showStructure: Bool,
        createAsPreview: Bool
    ) {
        if let oldTableName = tabManager.selectedTab?.tableContext.tableName {
            saveLastFilters(for: oldTableName)
        }
        do {
            try tabManager.replaceTabContent(
                tableName: tableName,
                databaseType: connection.type,
                isView: isView,
                databaseName: currentDatabase,
                schemaName: resolvedSchema,
                isPreview: createAsPreview
            )
        } catch {
            navigationLogger
                .error("openTableTab replaceTabContent failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        clearFilterState()
        if let (tab, tabIndex) = tabManager.selectedTabAndIndex {
            setActiveTableRows(TableRows(), for: tab.id)
            tabManager.mutate(at: tabIndex) {
                $0.display.resultsViewMode = showStructure ? .structure : .data
                $0.pagination.reset()
            }
            toolbarState.isTableTab = true
        }
        restoreLastHiddenColumnsForTable()
        restoreFiltersForTable(tableName)
        if let tabId = tabManager.selectedTab?.id {
            cancelTableLoad(for: tabId)
        }
        lazyLoadCurrentTabIfNeeded()
    }

    // MARK: - Preview Tabs

    /// Content the user authored that lives nowhere else, so replacing the tab in place would
    /// destroy it. Any navigation that reuses the selected tab must consult this first.
    var selectedTabHoldsProtectedContent: Bool {
        guard let tab = tabManager.selectedTab else { return false }
        if changeManager.hasChanges { return true }
        if tab.holdsQueryWork { return true }
        if tab.tabType == .createTable { return toolbarState.hasCreateTablePending }
        return false
    }

    var isActiveTabReusable: Bool {
        guard let tab = tabManager.selectedTab else { return false }
        if selectedTabHoldsProtectedContent { return false }
        if selectedTabFilterState.hasAppliedFilters
            || tab.hasUserActiveSort
            || tab.display.hasPinnedResults {
            return false
        }
        if tab.tabType == .createTable { return true }
        if tab.isPreview { return true }
        if tab.tabType == .query { return true }
        return false
    }

    func promotePreviewTab() {
        guard let (tab, tabIndex) = tabManager.selectedTabAndIndex,
              tab.isPreview else { return }
        tabManager.mutate(at: tabIndex) { $0.isPreview = false }
    }

    func showAllTablesMetadata() {
        guard let sql = allTablesMetadataSQL() else { return }

        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .query,
            initialQuery: sql
        )
        openTabInCurrentWindow(payload)
    }

    private func currentSchemaName(fallback: String) -> String {
        if let schemaDriver = DatabaseManager.shared.driver(for: connectionId) as? SchemaSwitchable,
           let schema = schemaDriver.escapedSchema {
            return schema
        }
        return fallback
    }

    private func allTablesMetadataSQL() -> String? {
        let editorLang = PluginManager.shared.editorLanguage(for: connection.type)
        // Non-SQL databases: open a command tab instead
        if editorLang == .javascript {
            tabManager.addTab(
                initialQuery: "db.runCommand({\"listCollections\": 1, \"nameOnly\": false})",
                databaseName: browseDatabaseName
            )
            runQuery()
            return nil
        } else if editorLang == .bash {
            tabManager.addTab(
                initialQuery: "SCAN 0 MATCH * COUNT 100",
                databaseName: browseDatabaseName
            )
            runQuery()
            return nil
        }

        // SQL databases: delegate to plugin driver
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return nil }
        let schema = (driver as? SchemaSwitchable)?.escapedSchema
        return (driver as? PluginDriverAdapter)?.allTablesMetadataSQL(schema: schema)
    }

    func dropDatabase(_ scope: DatabaseScope) async {
        if services.databaseManager.isDatabaseOpen(scope.database, for: scope.connectionId) {
            guard await DatabaseCloseFlow.closeDatabase(
                scope.database,
                connectionId: scope.connectionId,
                anchor: contentWindow
            ) else { return }
        }
        do {
            try await DatabaseTreeMetadataService.shared.dropDatabase(scope)
        } catch {
            navigationLogger.error("Failed to drop database: \(error.localizedDescription, privacy: .public)")
            AlertHelper.showErrorSheet(
                title: String(localized: "Drop Failed"),
                message: error.localizedDescription,
                window: contentWindow
            )
        }
    }

    // MARK: - Redis Database Selection

    /// Select a Redis database index and then run the query.
    /// Redis sidebar clicks go through openTableTab (sync), so we need a Task
    /// to call the async selectDatabase before executing the query.
    /// Cancels any previous in-flight switch to prevent race conditions
    /// from rapid sidebar clicks.
    private func selectRedisDatabaseAndQuery(_ dbIndex: Int) {
        cancelRedisDatabaseSwitchTask()

        let connId = connectionId
        let database = String(dbIndex)
        redisDatabaseSwitchTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let adapter = DatabaseManager.shared.driver(for: connId) as? PluginDriverAdapter {
                    try await adapter.switchDatabase(to: String(dbIndex))
                }
            } catch {
                if !Task.isCancelled {
                    navigationLogger
                        .error("Failed to SELECT Redis db\(dbIndex): \(error.localizedDescription, privacy: .public)")
                }
                return
            }
            guard !Task.isCancelled else { return }
            DatabaseManager.shared.updateSession(connId) { session in
                session.browseDatabase = database
            }
            toolbarState.currentDatabase = database
            executeTableTabQueryDirectly()

            let separator = connection.additionalFields["redisSeparator"] ?? ":"
            if sidebarViewModel?.redisKeyTreeViewModel == nil {
                let vm = RedisKeyTreeViewModel()
                sidebarViewModel?.redisKeyTreeViewModel = vm
                let sidebarState = SharedSidebarState.forConnection(connId)
                sidebarState.redisKeyTreeViewModel = vm
            }
            Task {
                await self.sidebarViewModel?.redisKeyTreeViewModel?.loadKeys(
                    connectionId: connId,
                    database: database,
                    separator: separator
                )
            }
        }
    }

    func initRedisKeyTreeIfNeeded() {
        guard connection.type == .redis else { return }
        let sidebarState = SharedSidebarState.forConnection(connectionId)
        guard sidebarState.redisKeyTreeViewModel == nil else { return }

        let vm = RedisKeyTreeViewModel()
        sidebarState.redisKeyTreeViewModel = vm
        sidebarViewModel?.redisKeyTreeViewModel = vm

        let connId = connectionId
        let database = toolbarState.currentDatabase
        let separator = connection.additionalFields["redisSeparator"] ?? ":"
        Task {
            await vm.loadKeys(connectionId: connId, database: database, separator: separator)
        }
    }

    // MARK: - Redis Key Tree Navigation

    func browseRedisNamespace(_ prefix: String) {
        applyBrowseSearch(BrowseSearchState(pattern: "\(prefix)*"))
    }

    func openRedisKey(_ keyName: String, keyType: String) {
        let escapedKey = keyName.replacingOccurrences(of: "\"", with: "\\\"")
        let query: String
        switch keyType.lowercased() {
        case "hash":
            query = "HGETALL \"\(escapedKey)\""
        case "list":
            query = "LRANGE \"\(escapedKey)\" 0 -1"
        case "set":
            query = "SMEMBERS \"\(escapedKey)\""
        case "zset":
            query = "ZRANGE \"\(escapedKey)\" 0 -1 WITHSCORES"
        case "stream":
            query = "XRANGE \"\(escapedKey)\" - +"
        default:
            query = "GET \"\(escapedKey)\""
        }
        tabManager.addTab(initialQuery: query, title: keyName)
        runQuery()
    }
}
