//
//  MainContentCoordinator+SQLPreview.swift
//  TablePro
//
//  SQL preview generation for MainContentCoordinator.
//

import Foundation

extension MainContentCoordinator {
    // MARK: - SQL Preview

    /// Routes SQL preview request to the appropriate handler based on current tab mode
    func handlePreviewSQL(
        pendingTruncates: Set<DatabaseTreeTableRef>,
        pendingDeletes: Set<DatabaseTreeTableRef>,
        tableOperationOptions: [DatabaseTreeTableRef: TableOperationOptions]
    ) {
        if tabManager.selectedTab?.display.resultsViewMode == .structure {
            // Structure view handles its own preview via direct call
            structureActions?.previewSQL?()
        } else {
            generatePreviewSQL(
                pendingTruncates: pendingTruncates,
                pendingDeletes: pendingDeletes,
                tableOperationOptions: tableOperationOptions
            )
        }
    }

    /// Generate SQL preview of all pending changes with inlined parameters
    func generatePreviewSQL(
        pendingTruncates: Set<DatabaseTreeTableRef>,
        pendingDeletes: Set<DatabaseTreeTableRef>,
        tableOperationOptions: [DatabaseTreeTableRef: TableOperationOptions]
    ) {
        do {
            let statements = try assemblePendingStatements(
                pendingTruncates: pendingTruncates,
                pendingDeletes: pendingDeletes,
                tableOperationOptions: tableOperationOptions
            )
            toolbarState.previewStatements = statements.map {
                SQLParameterInliner.inline($0, databaseType: connection.type)
            }
        } catch {
            toolbarState.previewStatements = ["-- Error generating SQL: \(error.localizedDescription)"]
        }
        activeSheet = .sqlPreview
    }

    func assemblePendingStatements(
        pendingTruncates: Set<DatabaseTreeTableRef>,
        pendingDeletes: Set<DatabaseTreeTableRef>,
        tableOperationOptions: [DatabaseTreeTableRef: TableOperationOptions]
    ) throws -> [ParameterizedStatement] {
        try assemblePendingBatches(
            tabScope: selectedTabScope,
            pendingTruncates: pendingTruncates,
            pendingDeletes: pendingDeletes,
            tableOperationOptions: tableOperationOptions
        ).flatMap(\.statements)
    }

    func assemblePendingBatches(
        tabScope: DatabaseScope?,
        pendingTruncates: Set<DatabaseTreeTableRef>,
        pendingDeletes: Set<DatabaseTreeTableRef>,
        tableOperationOptions: [DatabaseTreeTableRef: TableOperationOptions]
    ) throws -> [PendingStatementBatch] {
        let truncates = existingTables(pendingTruncates)
        let deletes = existingTables(pendingDeletes)
        let tabDatabase = tabScope?.database
        var databases = Set(truncates.union(deletes).map(\.database))
        if let tabDatabase { databases.insert(tabDatabase) }

        var batches: [PendingStatementBatch] = []
        for database in databases {
            let isTabBatch = database == tabDatabase
            let batchTruncates = truncates.filter { $0.database == database }
            let batchDeletes = deletes.filter { $0.database == database }
            let editStatements = isTabBatch && changeManager.hasChanges ? try changeManager.generateSQL() : []
            let statements = batchStatements(
                edits: editStatements,
                truncates: batchTruncates,
                deletes: batchDeletes,
                options: tableOperationOptions
            )
            guard !statements.isEmpty else { continue }
            let scope = isTabBatch
                ? tabScope ?? DatabaseScope(connectionId: connectionId, database: database, schema: nil)
                : DatabaseScope(connectionId: connectionId, database: database, schema: nil)
            batches.append(PendingStatementBatch(
                scope: scope,
                statements: statements,
                truncates: batchTruncates,
                deletes: batchDeletes
            ))
        }
        return batches.sorted { lhs, rhs in
            if lhs.scope.database == tabDatabase { return rhs.scope.database != tabDatabase }
            if rhs.scope.database == tabDatabase { return false }
            return lhs.scope.database < rhs.scope.database
        }
    }

    private func batchStatements(
        edits: [ParameterizedStatement],
        truncates: Set<DatabaseTreeTableRef>,
        deletes: Set<DatabaseTreeTableRef>,
        options: [DatabaseTreeTableRef: TableOperationOptions]
    ) -> [ParameterizedStatement] {
        let dbType = connection.type
        let needsDisableFK = PluginManager.shared.supportsForeignKeyDisable(for: dbType)
            && truncates.union(deletes).contains { options[$0]?.ignoreForeignKeys == true }
        let tableOpStatements = generateTableOperationSQL(
            truncates: truncates,
            deletes: deletes,
            options: options,
            includeFKHandling: false
        ).map { ParameterizedStatement(sql: $0, parameters: []) }
        guard !edits.isEmpty || !tableOpStatements.isEmpty else { return [] }

        let disable = needsDisableFK ? fkDisableStatements(for: dbType) : []
        let enable = needsDisableFK ? fkEnableStatements(for: dbType) : []
        return disable.map { ParameterizedStatement(sql: $0, parameters: []) }
            + edits
            + tableOpStatements
            + enable.map { ParameterizedStatement(sql: $0, parameters: []) }
    }

    func existingTables(_ refs: Set<DatabaseTreeTableRef>) -> Set<DatabaseTreeTableRef> {
        let service = DatabaseTreeMetadataService.shared
        return refs.filter { ref in
            guard ref.connectionId == connectionId else { return false }
            guard case .loaded(let tables) = service.tablesLoadState(
                connectionId: ref.connectionId,
                database: ref.database,
                schema: ref.schema
            ) else { return true }
            return tables.contains { $0.name == ref.table.name }
        }
    }
}

struct PendingStatementBatch {
    let scope: DatabaseScope
    let statements: [ParameterizedStatement]
    let truncates: Set<DatabaseTreeTableRef>
    let deletes: Set<DatabaseTreeTableRef>
}
