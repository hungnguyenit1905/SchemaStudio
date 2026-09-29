//
//  RowEditingCoordinator+SaveChanges.swift
//  TablePro
//

import Foundation
import os
import SwiftUI
import TableProPluginKit

private let saveChangesLogger = Logger(subsystem: "com.SchemaStudio", category: "RowEditingCoordinator")

extension RowEditingCoordinator {
    func saveChanges(
        pendingTruncates: inout Set<DatabaseTreeTableRef>,
        pendingDeletes: inout Set<DatabaseTreeTableRef>,
        tableOperationOptions: inout [DatabaseTreeTableRef: TableOperationOptions]
    ) {
        let hasEditedCells = parent.changeManager.hasChanges
        let hasPendingTableOps = !pendingTruncates.isEmpty || !pendingDeletes.isEmpty

        guard hasEditedCells || hasPendingTableOps else {
            parent.saveCompletionContinuation?.resume(returning: true)
            parent.saveCompletionContinuation = nil
            return
        }

        guard !parent.safeModeLevel.blocksAllWrites else {
            failSave(message: String(localized: "Cannot save changes: connection is read-only"))
            return
        }

        let tabScope = parent.selectedTabScope
        guard tabScope != nil || !hasEditedCells else {
            failSave(message: String(localized: "Not connected to database"))
            return
        }

        let batches: [PendingStatementBatch]
        do {
            batches = try parent.assemblePendingBatches(
                tabScope: tabScope,
                pendingTruncates: pendingTruncates,
                pendingDeletes: pendingDeletes,
                tableOperationOptions: tableOperationOptions
            )
        } catch {
            failSave(message: error.localizedDescription)
            return
        }

        guard !batches.isEmpty else {
            failSave(message: String(localized: "Could not generate SQL for changes."))
            return
        }

        let sqlPreview = batches.flatMap(\.statements).map(\.sql).joined(separator: ";\n")
        let snapshotOptions = tableOperationOptions
        if hasPendingTableOps {
            pendingTruncates.removeAll()
            pendingDeletes.removeAll()
            tableOperationOptions.removeAll()
        }
        let connId = parent.connection.id
        let kind: OperationKind = hasPendingTableOps ? .destructiveQuery : .writeQuery
        let deleteConfirmation = BulkDeleteConfirmation(deletedRowCount: parent.changeManager.deletedRowIndices.count)
        Task { [weak self, parent] in
            guard let self else { return }

            if deleteConfirmation.isRequired {
                let confirmed = await AlertHelper.confirmDestructive(
                    title: deleteConfirmation.title,
                    message: deleteConfirmation.message,
                    confirmButton: deleteConfirmation.confirmButtonTitle,
                    window: parent.contentWindow
                )
                guard confirmed else {
                    restorePendingTableOperations(connectionId: connId, batches: batches, options: snapshotOptions)
                    parent.saveCompletionContinuation?.resume(returning: false)
                    parent.saveCompletionContinuation = nil
                    return
                }
            }

            let decision = await ExecutionGateProvider.shared.authorize(
                OperationRequest(
                    connectionId: connId,
                    databaseType: parent.connection.type,
                    sql: sqlPreview,
                    kind: kind,
                    caller: .userInterface,
                    capabilities: .interactiveUser,
                    operationDescription: String(localized: "Save Changes")
                )
            )
            switch decision {
            case .authorized:
                executeCommitBatches(batches, tabScope: tabScope, options: snapshotOptions)
            case .denied(let reason):
                restorePendingTableOperations(connectionId: connId, batches: batches, options: snapshotOptions)
                failSave(message: reason)
            }
        }
    }

    private func executeCommitBatches(
        _ batches: [PendingStatementBatch],
        tabScope: DatabaseScope?,
        options: [DatabaseTreeTableRef: TableOperationOptions]
    ) {
        let conn = parent.connection
        let foreignKeyEnableStatements = parent.fkEnableStatements(for: conn.type)
        let supportsFKDisable = PluginManager.shared.supportsForeignKeyDisable(for: conn.type)

        Task { [weak self, parent] in
            guard let self else { return }
            var completed: [PendingStatementBatch] = []

            for batch in batches {
                let validStatements = batch.statements.filter {
                    !$0.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                guard !validStatements.isEmpty else {
                    completed.append(batch)
                    continue
                }
                let fkWasDisabled = supportsFKDisable
                    && batch.truncates.union(batch.deletes).contains { options[$0]?.ignoreForeignKeys == true }
                let startTime = Date()
                do {
                    let executionTimes = try await DatabaseManager.shared.withScopedDriver(
                        scope: batch.scope,
                        route: DatabaseManager.shared.executionRoute(for: batch.scope),
                        tracksCancellation: true
                    ) { driver in
                        try await Self.runStatementsInTransaction(
                            validStatements,
                            mode: .readWrite,
                            foreignKeyEnableStatements: fkWasDisabled ? foreignKeyEnableStatements : [],
                            on: driver
                        )
                    }
                    recordHistory(validStatements, times: executionTimes, database: batch.scope.database)
                    completed.append(batch)
                } catch {
                    recordFailure(validStatements, error: error, database: batch.scope.database, since: startTime)
                    finishCommit(completed: completed, tabScope: tabScope)
                    let remaining = batches.filter { candidate in
                        !completed.contains { $0.scope == candidate.scope }
                    }
                    restorePendingTableOperations(connectionId: conn.id, batches: remaining, options: options)
                    let diagnosis = DatabaseWriteRejectionDiagnosis.classify(error)
                    AlertHelper.showErrorSheet(
                        title: String(localized: "Save Failed"),
                        message: diagnosis?.errorDescription ?? error.localizedDescription,
                        recoverySuggestion: diagnosis?.recoverySuggestion,
                        window: parent.contentWindow
                    )
                    failSave(
                        message: String(
                            format: String(localized: "Save failed: %@"),
                            DatabaseWriteRejectionDiagnosis.formatted(error)
                        )
                    )
                    return
                }
            }

            finishCommit(completed: completed, tabScope: tabScope)
            if parent.tabManager.selectedTabIndex != nil, !parent.tabManager.tabs.isEmpty {
                parent.runQuery()
            }
            parent.saveCompletionContinuation?.resume(returning: true)
            parent.saveCompletionContinuation = nil
        }
    }

    private func finishCommit(completed: [PendingStatementBatch], tabScope: DatabaseScope?) {
        if completed.contains(where: { $0.scope == tabScope }) {
            parent.changeManager.clearChangesAndUndoHistory()
            if let index = parent.tabManager.selectedTabIndex {
                parent.tabManager.mutate(at: index) {
                    $0.pendingChanges = TabChangeSnapshot()
                    $0.execution.errorMessage = nil
                }
            }
        }
        let deleted = completed.reduce(into: Set<DatabaseTreeTableRef>()) { $0.formUnion($1.deletes) }
        closeTabs(showing: deleted)
        let touchedTables = completed.contains { !$0.truncates.isEmpty || !$0.deletes.isEmpty }
        guard touchedTables else { return }
        Task { [parent] in await parent.refreshTables() }
        let touchedScopes = Set(completed.flatMap { $0.truncates.union($0.deletes) }.map {
            DatabaseScope(connectionId: $0.connectionId, database: $0.database, schema: $0.schema)
        })
        for scope in touchedScopes {
            Task {
                await DatabaseTreeMetadataService.shared.refreshObjects(
                    connectionId: scope.connectionId,
                    database: scope.database,
                    schema: scope.schema
                )
            }
        }
    }

    private func closeTabs(showing deleted: Set<DatabaseTreeTableRef>) {
        guard !deleted.isEmpty else { return }
        let tabIdsToRemove = Set(
            parent.tabManager.tabs
                .filter { tab in
                    tab.tabType == .table && deleted.contains { ref in
                        tab.tableContext.tableName == ref.table.name
                            && tab.tableContext.databaseName == ref.database
                            && (ref.schema == nil || tab.tableContext.schemaName == ref.schema)
                    }
                }
                .map(\.id)
        )
        guard !tabIdsToRemove.isEmpty else { return }
        let firstRemovedIndex = parent.tabManager.tabs.firstIndex { tabIdsToRemove.contains($0.id) } ?? 0
        for tabId in tabIdsToRemove {
            parent.tabSessionRegistry.removeTableRows(for: tabId)
        }
        parent.tabManager.tabs.removeAll { tabIdsToRemove.contains($0.id) }
        if !parent.tabManager.tabs.isEmpty {
            let neighborIndex = min(firstRemovedIndex, parent.tabManager.tabs.count - 1)
            parent.tabManager.selectedTabId = parent.tabManager.tabs[neighborIndex].id
        } else {
            parent.tabManager.selectedTabId = nil
        }
    }

    private func recordHistory(_ statements: [ParameterizedStatement], times: [TimeInterval], database: String) {
        for (statement, executionTime) in zip(statements, times) {
            let historySQL = statement.sql.trimmingCharacters(in: .whitespacesAndNewlines)
            QueryHistoryManager.shared.recordQuery(
                query: historySQL.hasSuffix(";") ? historySQL : historySQL + ";",
                connectionId: parent.connection.id,
                databaseName: database,
                executionTime: executionTime,
                rowCount: 0,
                wasSuccessful: true,
                errorMessage: nil
            )
        }
    }

    private func recordFailure(
        _ statements: [ParameterizedStatement],
        error: Error,
        database: String,
        since startTime: Date
    ) {
        QueryHistoryManager.shared.recordQuery(
            query: statements.map(\.sql).joined(separator: "; "),
            connectionId: parent.connection.id,
            databaseName: database,
            executionTime: Date().timeIntervalSince(startTime),
            rowCount: 0,
            wasSuccessful: false,
            errorMessage: error.localizedDescription
        )
    }

    /// The rollback and the foreign-key re-enable are part of the same lease as the
    /// statements: resolving a driver again afterwards can reach a handle that has
    /// already been released, or one sitting on another database.
    nonisolated static func runStatementsInTransaction(
        _ statements: [ParameterizedStatement],
        mode: PluginTransactionAccessMode,
        foreignKeyEnableStatements: [String] = [],
        on driver: DatabaseDriver
    ) async throws -> [TimeInterval] {
        let useTransaction = driver.supportsTransactions
        if useTransaction {
            try await driver.beginTransaction(mode: mode)
        }

        var executionTimes: [TimeInterval] = []
        do {
            for statement in statements {
                let statementStartTime = Date()
                if statement.parameters.isEmpty {
                    _ = try await driver.execute(query: statement.sql)
                } else {
                    _ = try await driver.executeParameterized(query: statement.sql, parameters: statement.parameters)
                }
                executionTimes.append(Date().timeIntervalSince(statementStartTime))
            }

            if useTransaction {
                try await driver.commitTransaction()
            }
        } catch {
            if useTransaction {
                do {
                    try await driver.rollbackTransaction()
                } catch {
                    saveChangesLogger.error("Rollback failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            for statement in foreignKeyEnableStatements {
                do {
                    _ = try await driver.execute(query: statement)
                } catch {
                    saveChangesLogger
                        .warning(
                            "Failed to re-enable foreign key checks with statement '\(statement, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                        )
                }
            }
            throw error
        }
        return executionTimes
    }

    private func failSave(message: String) {
        if let index = parent.tabManager.selectedTabIndex {
            parent.tabManager.mutate(at: index) { $0.execution.errorMessage = message }
        }
        parent.saveCompletionContinuation?.resume(returning: false)
        parent.saveCompletionContinuation = nil
    }

    private func restorePendingTableOperations(
        connectionId: UUID,
        batches: [PendingStatementBatch],
        options: [DatabaseTreeTableRef: TableOperationOptions]
    ) {
        let truncates = batches.reduce(into: Set<DatabaseTreeTableRef>()) { $0.formUnion($1.truncates) }
        let deletes = batches.reduce(into: Set<DatabaseTreeTableRef>()) { $0.formUnion($1.deletes) }
        guard !truncates.isEmpty || !deletes.isEmpty else { return }
        DatabaseManager.shared.updateSession(connectionId) { session in
            session.pendingTruncates.formUnion(truncates)
            session.pendingDeletes.formUnion(deletes)
            for ref in truncates.union(deletes) {
                if let refOptions = options[ref] {
                    session.tableOperationOptions[ref] = refOptions
                }
            }
        }
    }
}
