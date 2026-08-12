//
//  DataTransferService+Phases.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

extension DataTransferService {
    /// Structure, then rows, then constraints, each pass covering every table
    /// before the next begins. A foreign key added right after its table would
    /// point at a table that does not exist yet, and rows loaded under live
    /// constraints would fail whenever a child table loads before its parent.
    /// Running the passes globally removes the need to order tables at all.
    func runPhases(
        selections: [TransferTableSelection],
        preview: TransferPreview,
        source: TransferDriverContext,
        target: TransferDriverContext,
        options: TransferOptions
    ) async throws -> TransferReport {
        var run = TransferRunState()
        for failure in preview.failures {
            run.fail(failure.table, message: failure.message)
        }

        let estimates = await estimatedRowCounts(for: preview.plans, source: source)

        await runStructurePhase(preview.plans, target: target, options: options, run: &run)
        await runDataPhase(
            preview.plans,
            source: source,
            target: target,
            options: options,
            estimates: estimates,
            run: &run
        )
        await runConstraintPhase(preview.plans, target: target, run: &run)

        return run.report(for: selections)
    }

    /// A TRUNCATE or DROP of a table another table points at is refused while
    /// the engine enforces its foreign keys (MySQL 1701 and 3730). The pass
    /// visits tables in an arbitrary order, so a parent is always reachable
    /// before its children are gone: the whole pass runs with the checks off.
    func runStructurePhase(
        _ plans: [TransferTablePlan],
        target: TransferDriverContext,
        options: TransferOptions,
        run: inout TransferRunState
    ) async {
        state.statusMessage = String(localized: "Preparing target tables\u{2026}")
        let foreignKeysDisabled = await disableForeignKeyChecks(on: target)
        await applyStructurePlans(plans, target: target, options: options, run: &run)
        if foreignKeysDisabled {
            await restoreForeignKeyChecks(on: target)
        }
        state.statusMessage = ""
    }

    private func applyStructurePlans(
        _ plans: [TransferTablePlan],
        target: TransferDriverContext,
        options: TransferOptions,
        run: inout TransferRunState
    ) async {
        for plan in plans where !run.isBlocked(plan.table) {
            if run.stopped || shouldStop {
                run.stopped = true
                return
            }
            do {
                try await applyStructureSteps(plan, target: target)
            } catch {
                run.fail(plan.table, message: error.localizedDescription)
                if !options.continueOnError { run.stopped = true
                    return
                }
            }
        }
    }

    private func disableForeignKeyChecks(on target: TransferDriverContext) async -> Bool {
        guard target.supportsForeignKeyCheckToggle else { return false }
        do {
            try await target.setForeignKeyChecks(enabled: false)
            return true
        } catch {
            Self.logger.warning(
                "Could not disable foreign key checks on target: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    private func restoreForeignKeyChecks(on target: TransferDriverContext) async {
        do {
            try await target.setForeignKeyChecks(enabled: true)
        } catch {
            Self.logger.error(
                "Could not restore foreign key checks on target: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func runDataPhase(
        _ plans: [TransferTablePlan],
        source: TransferDriverContext,
        target: TransferDriverContext,
        options: TransferOptions,
        estimates: [String: Int],
        run: inout TransferRunState
    ) async {
        let transferable = plans.filter { $0.steps.contains(.transferRows) }
        state.totalTables = transferable.count
        var index = 0

        for plan in transferable where !run.isBlocked(plan.table) {
            if run.stopped || shouldStop {
                run.stopped = true
                return
            }
            index += 1
            state.currentTable = plan.table
            state.currentTableIndex = index
            state.currentTableProcessedRows = 0
            state.currentTableEstimatedRows = estimates[plan.table] ?? 0

            let startedAt = Date()
            do {
                let rows = try await copyRows(plan: plan, source: source, target: target, options: options)
                run.succeed(plan.table, rows: rows, duration: Date().timeIntervalSince(startedAt))
                recordHistory(table: plan.table, rows: rows, target: target, startedAt: startedAt, error: nil)
            } catch is CancellationError {
                run.stopped = true
                return
            } catch {
                run.fail(plan.table, message: error.localizedDescription, duration: Date().timeIntervalSince(startedAt))
                recordHistory(table: plan.table, rows: 0, target: target, startedAt: startedAt, error: error)
                if !options.continueOnError { run.stopped = true
                    return
                }
            }
        }
    }

    /// `ALTER TABLE ... ADD CONSTRAINT FOREIGN KEY` validates every row already
    /// in the table, so a source that holds an orphan row aborts the statement
    /// (MySQL 1452). The transfer mirrors the source, the way `mysqldump` does,
    /// so the whole pass runs with the checks off.
    func runConstraintPhase(
        _ plans: [TransferTablePlan],
        target: TransferDriverContext,
        run: inout TransferRunState
    ) async {
        guard !run.stopped else { return }
        state.statusMessage = String(localized: "Adding indexes and foreign keys\u{2026}")
        defer { state.statusMessage = "" }

        let foreignKeysDisabled = await disableForeignKeyChecks(on: target)
        await applyConstraintPlans(plans, target: target, run: &run)
        if foreignKeysDisabled {
            await restoreForeignKeyChecks(on: target)
        }
    }

    /// A constraint that cannot be created never stops the run: the rows are
    /// already at the target, so the table is reported with a warning and the
    /// remaining tables keep going regardless of `continueOnError`.
    private func applyConstraintPlans(
        _ plans: [TransferTablePlan],
        target: TransferDriverContext,
        run: inout TransferRunState
    ) async {
        for plan in plans where !run.isBlocked(plan.table) {
            if shouldStop {
                run.stopped = true
                return
            }
            let messages = await applyConstraintSteps(plan, target: target)
            run.finish(plan.table)
            if !messages.isEmpty {
                run.warn(plan.table, messages: messages)
            }
        }
    }

    // MARK: - Steps

    private func applyStructureSteps(_ plan: TransferTablePlan, target: TransferDriverContext) async throws {
        for step in plan.steps {
            switch step {
            case .dropTargetTable:
                try await target.execute(target.dropTableStatement(plan.table))
            case .dropTargetTypes:
                for type in plan.structure.enumTypes {
                    guard let sql = target.dropEnumTypeStatement(type) else { continue }
                    try await target.execute(sql)
                }
            case .createTargetTypes:
                for type in plan.structure.enumTypes {
                    guard let sql = target.createEnumTypeStatement(type) else { continue }
                    try await target.execute(sql)
                }
            case .createTargetTable:
                guard let sql = target.createTableStatement(plan.structure.definition) else {
                    throw TransferError.createTableUnsupported(plan.table)
                }
                try await target.execute(sql)
            case .truncateTarget:
                for statement in target.truncateStatements(plan.table) {
                    try await target.execute(statement)
                }
            case .transferRows, .createIndexes, .createForeignKeys, .resetSequences, .failMissingTarget:
                continue
            }
        }
    }

    /// One message per statement that failed rather than a throw on the first,
    /// so a rejected index never costs the same table its foreign keys.
    private func applyConstraintSteps(
        _ plan: TransferTablePlan,
        target: TransferDriverContext
    ) async -> [String] {
        var messages: [String] = []

        for step in plan.steps {
            switch step {
            case .createIndexes:
                for index in plan.structure.indexes {
                    guard let sql = target.addIndexStatement(table: plan.table, index: index) else { continue }
                    await Self.appendFailure(of: sql, on: target, to: &messages)
                }
            case .createForeignKeys:
                for foreignKey in plan.structure.foreignKeys {
                    guard let sql = target.addForeignKeyStatement(table: plan.table, foreignKey: foreignKey) else {
                        continue
                    }
                    await Self.appendFailure(of: sql, on: target, to: &messages)
                }
            case .resetSequences:
                for column in plan.structure.autoIncrementColumns {
                    guard let sql = target.resetSequenceStatement(table: plan.table, column: column) else { continue }
                    await Self.appendFailure(of: sql, on: target, to: &messages)
                }
            case .dropTargetTable, .dropTargetTypes, .createTargetTypes, .createTargetTable,
                 .truncateTarget, .transferRows, .failMissingTarget:
                continue
            }
        }

        return messages
    }

    private static func appendFailure(
        of statement: String,
        on target: TransferDriverContext,
        to messages: inout [String]
    ) async {
        do {
            try await target.execute(statement)
        } catch {
            messages.append(error.localizedDescription)
            logger.warning(
                "Transfer constraint statement failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Row Copy

    private func copyRows(
        plan: TransferTablePlan,
        source: TransferDriverContext,
        target: TransferDriverContext,
        options: TransferOptions
    ) async throws -> Int {
        let dataSource = ExportDataSourceAdapter(driver: source.driver, databaseType: source.databaseType)
        let stream = dataSource.streamRows(table: plan.table, databaseName: source.containerName)

        var sink: ImportDataSinkAdapter?
        var headerColumns: [String] = []
        var pending: [[String: PluginCellValue]] = []
        var written = 0
        var transactionOpen = false
        var foreignKeysDisabled = false

        do {
            for try await element in stream {
                if shouldStop { throw CancellationError() }

                switch element {
                case .header(let header):
                    headerColumns = header.columns
                    sink = try makeSink(plan: plan, header: header, target: target)
                    if options.useSingleTransaction {
                        try await target.driver.beginTransaction(mode: .readWrite)
                        transactionOpen = true
                    }
                    try await sink?.disableForeignKeyChecks()
                    foreignKeysDisabled = true
                case .rows(let rows):
                    guard let sink else { throw TransferError.structureUnavailable(plan.table) }
                    for row in rows {
                        pending.append(Self.rowDictionary(row, columns: headerColumns))
                    }
                    guard pending.count >= Self.batchRowCount else { continue }
                    written += try await flush(&pending, into: sink)
                }
            }

            if let sink, !pending.isEmpty {
                written += try await flush(&pending, into: sink)
            }
            if foreignKeysDisabled {
                try await sink?.enableForeignKeyChecks()
            }
            if transactionOpen {
                try await target.driver.commitTransaction()
                transactionOpen = false
            }
            return written
        } catch {
            if transactionOpen {
                try? await target.driver.rollbackTransaction()
            }
            if foreignKeysDisabled {
                try? await sink?.enableForeignKeyChecks()
            }
            throw error
        }
    }

    private func flush(
        _ pending: inout [[String: PluginCellValue]],
        into sink: ImportDataSinkAdapter
    ) async throws -> Int {
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        try await sink.insertRows(batch)
        state.processedRows += batch.count
        state.currentTableProcessedRows += batch.count
        return batch.count
    }

    private func makeSink(
        plan: TransferTablePlan,
        header: PluginStreamHeader,
        target: TransferDriverContext
    ) throws -> ImportDataSinkAdapter {
        let generated = plan.structure.generatedColumns
        let mapping = Self.identityColumnMapping(headerColumns: header.columns, generatedColumns: generated)
        try Self.validateColumnMapping(
            table: plan.table,
            headerColumns: header.columns,
            generatedColumns: generated,
            mapping: mapping
        )

        let generator = try SQLStatementGenerator(
            tableName: plan.table,
            columns: header.columns.filter { !generated.contains($0) },
            primaryKeyColumns: plan.structure.primaryKeyColumns,
            databaseType: target.databaseType,
            generatedColumns: generated,
            quoteIdentifier: target.driver.quoteIdentifier
        )

        return ImportDataSinkAdapter(
            driver: target.driver,
            databaseType: target.databaseType,
            targetTable: plan.table,
            columnMapping: mapping,
            rowGenerator: generator
        )
    }

    static func rowDictionary(_ row: PluginRow, columns: [String]) -> [String: PluginCellValue] {
        var values: [String: PluginCellValue] = [:]
        for (index, column) in columns.enumerated() where index < row.count {
            values[column] = row[index]
        }
        return values
    }

    /// Source and target share a table definition here, so every column maps
    /// onto itself. Server-computed columns are left out: they reject a
    /// written value.
    static func identityColumnMapping(
        headerColumns: [String],
        generatedColumns: Set<String>
    ) -> [String: String] {
        var mapping: [String: String] = [:]
        for column in headerColumns where !generatedColumns.contains(column) {
            mapping[column] = column
        }
        return mapping
    }

    /// A sink with an empty mapping drops every row and reports success, so an
    /// incomplete mapping has to stop the run rather than write silence.
    static func validateColumnMapping(
        table: String,
        headerColumns: [String],
        generatedColumns: Set<String>,
        mapping: [String: String]
    ) throws {
        guard !mapping.isEmpty else { throw TransferError.emptyColumnMapping(table) }
        let expected = headerColumns.filter { !generatedColumns.contains($0) }
        guard mapping.count == Set(expected).count else {
            throw TransferError.columnMappingIncomplete(table)
        }
    }

    // MARK: - Helpers

    /// The estimate is only ever the denominator of the table currently
    /// copying, so a table the driver cannot estimate is absent rather than
    /// counted as zero.
    private func estimatedRowCounts(
        for plans: [TransferTablePlan],
        source: TransferDriverContext
    ) async -> [String: Int] {
        var counts: [String: Int] = [:]
        for plan in plans where plan.steps.contains(.transferRows) {
            guard let count = try? await source.approximateRowCount(table: plan.table) else { continue }
            counts[plan.table] = count
        }
        return counts
    }

    private func recordHistory(
        table: String,
        rows: Int,
        target: TransferDriverContext,
        startedAt: Date,
        error: Error?
    ) {
        QueryHistoryManager.shared.recordQuery(
            query: "-- Data Transfer: \(table)",
            connectionId: target.endpoint.connectionId,
            databaseName: target.endpoint.database,
            executionTime: Date().timeIntervalSince(startedAt),
            rowCount: rows,
            wasSuccessful: error == nil,
            errorMessage: error?.localizedDescription
        )
    }
}

// MARK: - Run State

struct TransferRunState {
    private static let constraintsNotAppliedMessage = String(
        localized: "Rows were copied but indexes and foreign keys were not applied."
    )

    private var rows: [String: Int] = [:]
    private var durations: [String: TimeInterval] = [:]
    private var failures: [String: String] = [:]
    private var warnings: [String: [String]] = [:]
    private var finished: Set<String> = []

    var stopped = false

    func isBlocked(_ table: String) -> Bool { failures[table] != nil }

    mutating func fail(_ table: String, message: String, duration: TimeInterval = 0) {
        failures[table] = message
        durations[table] = duration
    }

    /// A warning never stops the run and never blocks the table, so every later
    /// phase still visits it.
    mutating func warn(_ table: String, messages: [String]) {
        warnings[table, default: []].append(contentsOf: messages)
    }

    mutating func succeed(_ table: String, rows count: Int, duration: TimeInterval) {
        rows[table] = count
        durations[table] = duration
    }

    mutating func finish(_ table: String) {
        finished.insert(table)
    }

    func report(for selections: [TransferTableSelection]) -> TransferReport {
        let results = selections.map { selection -> TransferTableResult in
            TransferTableResult(
                table: selection.table,
                rowsTransferred: rows[selection.table] ?? 0,
                duration: durations[selection.table] ?? 0,
                outcome: outcome(for: selection.table)
            )
        }
        return TransferReport(results: results, wasCancelled: stopped)
    }

    /// A table whose rows landed before the run stopped is not "not completed":
    /// the data is at the target, only its constraints are missing.
    private func outcome(for table: String) -> TransferTableOutcome {
        if let message = failures[table] { return .failed(message) }
        if finished.contains(table) {
            guard let messages = warnings[table], !messages.isEmpty else { return .succeeded }
            return .warned(messages)
        }
        guard rows[table] != nil else { return .notRun }
        return .warned([Self.constraintsNotAppliedMessage])
    }
}
