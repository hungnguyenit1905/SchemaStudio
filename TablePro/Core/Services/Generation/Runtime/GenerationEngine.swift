//
//  GenerationEngine.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

struct GenerationRunOptions: Sendable {
    /// The whole run in one transaction, so a failure leaves the database as it
    /// was. Above roughly a million rows this is what fills the server's undo
    /// space, and the engine warns before starting.
    var singleTransaction = false
    var continueOnError = false
    var referencePoolLimit = 100_000
    var referenceStrategy: ReferencePoolStrategy = .random
    var singleTransactionRowWarningThreshold = 1_000_000
}

/// Runs a compiled plan. Never touches the main actor: the only thing that
/// crosses to the UI is the throttled event stream.
actor GenerationEngine {
    private static let logger = Logger(subsystem: "com.SchemaStudio", category: "GenerationEngine")
    private static let cancellationCheckInterval = 1_000

    private let driver: any GenerationDriver
    private let registry: GeneratorRegistry
    private let truncator: GenerationStringTruncator
    private let options: GenerationRunOptions
    private let maxBindParameters: Int

    private var isCancelled = false
    private var harvested: [GenerationTableReference: HarvestedKeys] = [:]

    private struct HarvestedKeys {
        let columns: [String]
        let rows: [[PluginCellValue]]

        func project(_ wanted: [String]) -> [[PluginCellValue]]? {
            let positions = wanted.compactMap { columns.firstIndex(of: $0) }
            guard positions.count == wanted.count else { return nil }
            return rows.compactMap { row in
                guard positions.allSatisfy({ $0 < row.count }) else { return nil }
                return positions.map { row[$0] }
            }
        }
    }

    init(
        driver: any GenerationDriver,
        registry: GeneratorRegistry = .standard,
        truncator: GenerationStringTruncator = GenerationStringTruncator(unit: .unicodeScalars),
        maxBindParameters: Int = 65_535,
        options: GenerationRunOptions = GenerationRunOptions()
    ) {
        self.driver = driver
        self.registry = registry
        self.truncator = truncator
        self.options = options
        self.maxBindParameters = maxBindParameters
    }

    func cancel() {
        isCancelled = true
    }

    nonisolated func run(plan: GenerationPlan) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.execute(plan: plan, continuation: continuation)
            }
            continuation.onTermination = { termination in
                guard case .cancelled = termination else { return }
                task.cancel()
                Task { await self.cancel() }
            }
        }
    }

    private func execute(
        plan: GenerationPlan,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async {
        let startedAt = Date()
        var reports: [GenerationTableReport] = []
        var warnings: [GenerationWarning] = []
        let hooks = GenerationTableHooks(driver: driver)

        continuation.yield(.started(totalTables: plan.tables.count, totalRows: plan.totalRowCount))
        if options.singleTransaction, plan.totalRowCount > options.singleTransactionRowWarningThreshold {
            continuation.yield(
                .warning(
                    String(
                        format: String(
                            localized: "Generating %d rows in a single transaction can exhaust the server's undo space."
                        ),
                        plan.totalRowCount
                    )
                )
            )
        }

        var transactionOpen = false
        do {
            try await hooks.preflight(plan: plan)
            if plan.requiresConstraintDisable {
                try await hooks.disableForeignKeyChecks()
            }
            if options.singleTransaction, driver.supportsTransactions {
                try await driver.beginTransaction()
                transactionOpen = true
            }

            let limits = try? await driver.serverLimits()
            for table in plan.tables {
                try await generate(
                    table: table,
                    plan: plan,
                    limits: limits,
                    hooks: hooks,
                    reports: &reports,
                    warnings: &warnings,
                    continuation: continuation
                )
            }

            if transactionOpen {
                try await driver.commitTransaction()
                transactionOpen = false
            }
            await hooks.restoreForeignKeyChecks()
            continuation.yield(
                .finished(
                    report: GenerationReport(
                        tables: reports,
                        warnings: warnings,
                        duration: Date().timeIntervalSince(startedAt),
                        wasCancelled: false
                    )
                )
            )
            continuation.finish()
        } catch is CancellationError {
            if transactionOpen { try? await driver.rollbackTransaction() }
            await hooks.restoreForeignKeyChecks()
            let written = reports.reduce(0) { $0 + $1.rowsWritten }
            continuation.yield(.cancelled(rowsWritten: transactionOpen ? 0 : written))
            continuation.finish()
        } catch {
            if transactionOpen { try? await driver.rollbackTransaction() }
            await hooks.restoreForeignKeyChecks()
            Self.logger.error("Generation failed: \(error.localizedDescription, privacy: .public)")
            continuation.finish(throwing: error)
        }
    }

    private func generate(
        table: TablePlan,
        plan: GenerationPlan,
        limits: PluginServerLimits?,
        hooks: GenerationTableHooks,
        reports: inout [GenerationTableReport],
        warnings: inout [GenerationWarning],
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        let startedAt = Date()
        continuation.yield(.tableStarted(table: table.qualifiedName, rowCount: table.rowCount))
        try await hooks.emptyTable(table)

        let builder = try RowBuilder(
            plan: table,
            truncator: truncator,
            registry: registry,
            runSeed: plan.seed
        )
        try await bindPools(to: builder, table: table, runSeed: plan.seed, continuation: continuation)

        let harvestColumns = Self.harvestColumns(for: table.reference, in: plan)
        let writer = GenerationWriter(
            driver: driver,
            table: table.reference,
            columns: table.insertColumns,
            harvestColumns: harvestColumns,
            limits: limits,
            maxBindParameters: maxBindParameters,
            continueOnError: options.continueOnError
        )

        var throttle = GenerationProgressThrottle()
        var reportedFailures = 0
        do {
            for index in 0 ..< table.rowCount {
                if index % Self.cancellationCheckInterval == 0 {
                    try checkCancellation()
                }
                try await writer.append(builder.buildRow(index: index))
                reportedFailures = report(
                    failures: writer.failedBatches,
                    alreadyReported: reportedFailures,
                    table: table.qualifiedName,
                    continuation: continuation
                )
                if throttle.shouldEmit(
                    rowsWritten: writer.rowsWritten,
                    totalRows: table.rowCount,
                    now: Date().timeIntervalSinceReferenceDate
                ) {
                    continuation.yield(
                        .progress(
                            table: table.qualifiedName,
                            rowsWritten: writer.rowsWritten,
                            totalRows: table.rowCount
                        )
                    )
                }
            }
            try await writer.flush()
        } catch {
            reports.append(Self.tableReport(table: table, writer: writer, startedAt: startedAt))
            throw error
        }
        _ = report(
            failures: writer.failedBatches,
            alreadyReported: reportedFailures,
            table: table.qualifiedName,
            continuation: continuation
        )

        if let rows = writer.harvestedRows, !harvestColumns.isEmpty {
            harvested[table.reference] = HarvestedKeys(columns: harvestColumns, rows: rows)
        }
        warnings.append(contentsOf: builder.warnings)
        if !table.deferredColumns.isEmpty {
            let message = String(
                format: String(
                    localized: "%@ is written with %@ left empty, because the rows they point at do not exist yet."
                ),
                table.qualifiedName,
                table.deferredColumns.joined(separator: ", ")
            )
            warnings.append(GenerationWarning(column: table.deferredColumns.joined(separator: ", "), message: message))
            continuation.yield(.warning(message))
        }

        let report = Self.tableReport(table: table, writer: writer, startedAt: startedAt)
        continuation.yield(
            .tableFinished(
                table: table.qualifiedName,
                rowsWritten: report.rowsWritten,
                duration: report.duration
            )
        )
        reports.append(report)
    }

    private static func tableReport(
        table: TablePlan,
        writer: GenerationWriter,
        startedAt: Date
    ) -> GenerationTableReport {
        GenerationTableReport(
            table: table.qualifiedName,
            rowsRequested: table.rowCount,
            rowsWritten: writer.rowsWritten,
            failedBatches: writer.failedBatches.count,
            duration: Date().timeIntervalSince(startedAt)
        )
    }

    private func report(
        failures: [String],
        alreadyReported: Int,
        table: String,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) -> Int {
        guard failures.count > alreadyReported else { return alreadyReported }
        for failure in failures[alreadyReported...] {
            continuation.yield(.batchFailed(table: table, error: failure))
        }
        return failures.count
    }

    private func checkCancellation() throws {
        guard isCancelled || Task.isCancelled else { return }
        throw CancellationError()
    }

    private func bindPools(
        to builder: RowBuilder,
        table: TablePlan,
        runSeed: UInt64,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        for requirement in builder.referenceRequirements {
            let key = ReferenceKey(
                schema: requirement.target.schema,
                table: requirement.target.table,
                columns: [requirement.target.column]
            )
            let tuples = try await values(for: key)
            guard !tuples.isEmpty else {
                try degrade(
                    requirement: requirement,
                    table: table,
                    key: key,
                    continuation: continuation
                )
                builder.bind(pool: ReferenceValuePool(target: requirement.target, values: [.null]))
                continue
            }
            builder.bind(
                pool: ReferenceValuePool(target: requirement.target, values: tuples.map { $0[0] })
            )
        }

        for requirement in builder.compositeRequirements {
            let tuples = try await values(for: requirement.key)
            guard !tuples.isEmpty else {
                try degrade(
                    requirement: requirement,
                    table: table,
                    key: requirement.key,
                    continuation: continuation
                )
                builder.bind(
                    compositePool: try ReferencePool(
                        key: requirement.key,
                        tuples: [requirement.localColumns.map { _ in PluginCellValue.null }],
                        strategy: .random,
                        seed: poolSeed(for: requirement.key, table: table, runSeed: runSeed)
                    )
                )
                continue
            }
            builder.bind(
                compositePool: try ReferencePool(
                    key: requirement.key,
                    tuples: tuples,
                    strategy: options.referenceStrategy,
                    seed: poolSeed(for: requirement.key, table: table, runSeed: runSeed),
                    rowCount: table.rowCount
                )
            )
        }
    }

    private func degrade(
        requirement: some ReferenceRequiring,
        table: TablePlan,
        key: ReferenceKey,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) throws {
        guard requirement.isNullable else {
            throw GenerationError.emptyParentTable(
                table: table.qualifiedName,
                column: requirement.localColumnList,
                parentTable: key.qualifiedName
            )
        }
        continuation.yield(
            .warning(
                String(
                    format: String(localized: "%@ is empty, so %@.%@ is left empty."),
                    key.qualifiedName,
                    table.qualifiedName,
                    requirement.localColumnList
                )
            )
        )
    }

    private func values(for key: ReferenceKey) async throws -> [[PluginCellValue]] {
        let reference = GenerationTableReference(schema: key.schema, table: key.table)
        if let keys = harvested[reference], let projected = keys.project(key.columns), !projected.isEmpty {
            return projected
        }
        return try await driver.loadDistinctValues(key: key, limit: options.referencePoolLimit)
    }

    private func poolSeed(for key: ReferenceKey, table: TablePlan, runSeed: UInt64) -> UInt64 {
        GenerationSeed.columnSeed(
            runSeed: runSeed,
            table: table.qualifiedName,
            column: "\(key.qualifiedName).\(key.columns.joined(separator: ","))"
        )
    }

    private static func harvestColumns(for table: GenerationTableReference, in plan: GenerationPlan) -> [String] {
        var wanted: [String] = []
        for other in plan.tables {
            for column in other.columns {
                guard let key = column.column.foreignKey else { continue }
                let parent = GenerationTableReference(
                    schema: key.referencedSchema ?? other.reference.schema,
                    table: key.referencedTable
                )
                guard parent == table else { continue }
                for referenced in key.referencedColumns where !wanted.contains(referenced) {
                    wanted.append(referenced)
                }
            }
        }
        return wanted
    }
}
