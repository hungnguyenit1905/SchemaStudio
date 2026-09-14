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
    var referenceStrategy: ReferenceStrategy = .random
    var singleTransactionRowWarningThreshold = 1_000_000

    /// Turns foreign key checks off for the whole run, not only for the cycle
    /// `DependencyResolver` could not otherwise order. A driver that cannot
    /// honour this reports it as unsupported rather than silently ignoring it.
    var disablesForeignKeyChecks = false

    /// Turns triggers off per table, for the tables this run writes to.
    /// Reported as skipped on an engine that cannot do it (MySQL, SQLite).
    /// Never issued while `singleTransaction` is on and the driver supports
    /// transactions, since an `ALTER` there could commit the run's
    /// transaction early on an engine whose trigger DDL is not transactional.
    var disablesTriggers = false

    /// Records how far each table got so an interrupted run continues instead of
    /// starting over. Never used with `singleTransaction`, where an interruption
    /// rolls the whole run back and there is nothing on the server to resume onto.
    var isResumable = true

    /// Uses the vendor's bulk load path (`COPY`, `LOAD DATA LOCAL INFILE`) where
    /// the target has one. The prepared-batch path stays the fallback and runs
    /// whenever the route rules bulk out.
    var usesBulkLoad = true
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
    private let databaseType: DatabaseType
    private let maxBindParameters: Int?
    private let checkpoints: GenerationCheckpointStore
    private let onForeignKeyRestoreFailed: (@Sendable () async -> Void)?

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

    /// `maxBindParameters` is an explicit override for a caller that already
    /// knows the right ceiling; leaving it `nil` computes it from `databaseType`
    /// and whatever `serverLimits()` reports at run time, through the same
    /// `TransferBindParameterLimits` Data Transfer uses, so SQLite and SQL
    /// Server get their own ceiling instead of PostgreSQL's when the server
    /// reports no limits of its own.
    init(
        driver: any GenerationDriver,
        registry: GeneratorRegistry = .standard,
        truncator: GenerationStringTruncator = GenerationStringTruncator(unit: .unicodeScalars),
        databaseType: DatabaseType = .postgresql,
        maxBindParameters: Int? = nil,
        options: GenerationRunOptions = GenerationRunOptions(),
        checkpoints: GenerationCheckpointStore = .shared,
        onForeignKeyRestoreFailed: (@Sendable () async -> Void)? = nil
    ) {
        self.driver = driver
        self.registry = registry
        self.truncator = truncator
        self.options = options
        self.databaseType = databaseType
        self.maxBindParameters = maxBindParameters
        self.checkpoints = checkpoints
        self.onForeignKeyRestoreFailed = onForeignKeyRestoreFailed
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
            if plan.requiresConstraintDisable || options.disablesForeignKeyChecks {
                if driver.canDisableForeignKeyChecks {
                    try await hooks.disableForeignKeyChecks()
                } else {
                    let message = String(
                        localized: "Foreign key checks cannot be disabled by this engine. The run continues with them on."
                    )
                    warnings.append(GenerationWarning(column: "", message: message))
                    continuation.yield(.warning(message))
                }
            }
            if options.singleTransaction, driver.supportsTransactions {
                try await driver.beginTransaction()
                transactionOpen = true
            }

            let limits = try? await driver.serverLimits()
            let resume = await resumePoints(plan: plan)
            for table in plan.tables {
                try await generate(
                    table: table,
                    plan: plan,
                    limits: limits,
                    resume: resume[table.qualifiedName],
                    hooks: hooks,
                    reports: &reports,
                    warnings: &warnings,
                    continuation: continuation
                )
            }
            try await runSecondPasses(plan: plan, warnings: &warnings, continuation: continuation)

            if transactionOpen {
                try await driver.commitTransaction()
                transactionOpen = false
            }
            await resetSequences(plan: plan, warnings: &warnings, continuation: continuation)
            await handleForeignKeyRestore(hooks: hooks, warnings: &warnings, continuation: continuation)
            await clearCheckpoints(plan: plan)
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
            await handleForeignKeyRestore(hooks: hooks, warnings: &warnings, continuation: continuation)
            let written = reports.reduce(0) { $0 + $1.rowsWritten }
            continuation.yield(.cancelled(rowsWritten: transactionOpen ? 0 : written))
            continuation.finish()
        } catch {
            if transactionOpen { try? await driver.rollbackTransaction() }
            await handleForeignKeyRestore(hooks: hooks, warnings: &warnings, continuation: continuation)
            Self.logger.error("Generation failed: \(error.localizedDescription, privacy: .public)")
            continuation.finish(throwing: error)
        }
    }

    /// A failed restore is never silently swallowed: the caller learns about it
    /// through a warning, the driver-level flag stays true so nobody mistakes the
    /// connection for clean, and whoever built the engine gets a chance to make
    /// sure this connection is never handed out again with checks left off.
    private func handleForeignKeyRestore(
        hooks: GenerationTableHooks,
        warnings: inout [GenerationWarning],
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async {
        guard let warning = await hooks.restoreForeignKeyChecks() else { return }
        warnings.append(warning)
        continuation.yield(.warning(warning.message))
        await onForeignKeyRestoreFailed?()
    }

    private func generate(
        table: TablePlan,
        plan: GenerationPlan,
        limits: PluginServerLimits?,
        resume: GenerationCheckpoint?,
        hooks: GenerationTableHooks,
        reports: inout [GenerationTableReport],
        warnings: inout [GenerationWarning],
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        let startedAt = Date()
        continuation.yield(.tableStarted(table: table.qualifiedName, rowCount: table.rowCount))
        // A table the profile empties first has nothing worth resuming onto only
        // when an earlier attempt was interrupted: the rows it wrote are the ones
        // this run is about to delete. A table that already finished is not being
        // resumed at all, and discarding its checkpoint here would empty and
        // regenerate a table the docs promise stays untouched.
        let resume = (table.emptyFirst && resume?.isComplete != true) ? nil : resume
        if resume?.isComplete == true {
            reports.append(Self.skippedReport(table: table, startedAt: startedAt))
            continuation.yield(
                .tableFinished(
                    table: table.qualifiedName,
                    rowsWritten: table.rowCount,
                    duration: Date().timeIntervalSince(startedAt)
                )
            )
            return
        }

        let managesTriggers = options.disablesTriggers && (!driver.supportsTransactions || !options.singleTransaction)
        if managesTriggers, let warning = await hooks.disableTriggers(for: table) {
            warnings.append(warning)
            continuation.yield(.warning(warning.message))
        }

        do {
            try await writeRows(
                table: table,
                plan: plan,
                limits: limits,
                resume: resume,
                startedAt: startedAt,
                hooks: hooks,
                reports: &reports,
                warnings: &warnings,
                continuation: continuation
            )
        } catch {
            if managesTriggers, let warning = await hooks.restoreTriggers(for: table) {
                warnings.append(warning)
                continuation.yield(.warning(warning.message))
            }
            throw error
        }
        if managesTriggers, let warning = await hooks.restoreTriggers(for: table) {
            warnings.append(warning)
            continuation.yield(.warning(warning.message))
        }
    }

    /// The row loop and everything hung off it: building rows, routing to bulk
    /// load or prepared batches, checkpointing and the table's final report.
    /// Split out of `generate` so trigger disable and restore, which wrap this
    /// whole thing, do not have to reach into the writer this creates.
    private func writeRows(
        table: TablePlan,
        plan: GenerationPlan,
        limits: PluginServerLimits?,
        resume: GenerationCheckpoint?,
        startedAt: Date,
        hooks: GenerationTableHooks,
        reports: inout [GenerationTableReport],
        warnings: inout [GenerationWarning],
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        let firstRow = min(max(resume?.rowsWritten ?? 0, 0), table.rowCount)
        if firstRow == 0 {
            try await hooks.emptyTable(table)
        }

        let builder = try RowBuilder(
            plan: table,
            truncator: truncator,
            registry: registry,
            runSeed: plan.seed
        )
        try await bindPools(to: builder, table: table, runSeed: plan.seed, continuation: continuation)
        try fastForward(builder: builder, to: firstRow)

        // A resumed table has no record of the keys its earlier batches wrote, so
        // it never claims to harvest: a child re-reads the parent instead.
        let harvestColumns = firstRow == 0 ? Self.harvestColumns(for: table.reference, in: plan) : []
        let route = GenerationBulkLoadRoute.resolve(
            supportsBulkLoad: options.usesBulkLoad && driver.supportsBulkLoad,
            supportsLocalInfile: limits?.supportsLocalInfile,
            requiresLocalInfile: driver.requiresLocalInfile,
            continueOnError: options.continueOnError,
            harvestRequired: !harvestColumns.isEmpty,
            isResumedMidTable: firstRow > 0
        )
        Self.logger.info(
            """
            \(table.qualifiedName, privacy: .public) writes through \
            \(route.strategy == .bulk ? "bulk load" : "prepared batches", privacy: .public)\
            \(route.reason.map { ": \($0.rawValue)" } ?? "", privacy: .public)
            """
        )
        let writer = GenerationWriter(
            driver: driver,
            table: table.reference,
            columns: table.insertColumns,
            harvestColumns: harvestColumns,
            limits: limits,
            maxBindParameters: maxBindParameters
                ?? TransferBindParameterLimits.maxBindParameters(for: databaseType, limits: limits),
            continueOnError: options.continueOnError,
            strategy: route.strategy,
            rowsAlreadyWritten: firstRow,
            onBatchWritten: checkpointRecorder(plan: plan, table: table)
        )

        var throttle = GenerationProgressThrottle()
        var reportedFailures = 0
        do {
            for index in firstRow ..< table.rowCount {
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
            try await writer.finish()
        } catch {
            await writer.abort()
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

        await recordCheckpoint(
            plan: plan,
            entry: GenerationCheckpoint(
                table: table.qualifiedName,
                rowsWritten: writer.rowsWritten,
                isComplete: true
            )
        )

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

    /// Runs after the transaction has committed, never inside it. MySQL's
    /// `ALTER TABLE ... AUTO_INCREMENT` is DDL and commits implicitly, so resetting
    /// a sequence mid-run would end the run's transaction early and leave a later
    /// failure only half rolled back. A run that never commits needs no reset
    /// anyway: the rows it wrote are gone.
    ///
    /// The rows are already committed by the time this runs, so a reset failure
    /// is a warning, never a run failure: reporting the run as failed for rows
    /// that landed correctly would be a lie, and it would also skip
    /// `clearCheckpoints`, leaving a resumed retry as a no-op that reports success
    /// without ever resetting the sequence either.
    private func resetSequences(
        plan: GenerationPlan,
        warnings: inout [GenerationWarning],
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async {
        let resetter = SequenceResetter(driver: driver)
        for table in plan.tables where !table.sequenceBackedColumns.isEmpty {
            let failures = await resetter.reset(table: table)
            warnings.append(contentsOf: failures)
            for failure in failures {
                continuation.yield(.warning(failure.message))
            }
        }
    }

    /// Runs once every table has rows, because that is the earliest point at which
    /// the keys a deferred column has to point at exist.
    private func runSecondPasses(
        plan: GenerationPlan,
        warnings: inout [GenerationWarning],
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        let updater = SecondPassUpdater(driver: driver, poolLimit: options.referencePoolLimit)
        for table in plan.tables where !table.deferredColumns.isEmpty {
            try checkCancellation()
            let harvestedOwnKeys = harvested[table.reference]?.project(table.primaryKeyColumns)
            let outcome = try await updater.fill(
                table: table,
                runSeed: plan.seed,
                harvestedOwnKeys: harvestedOwnKeys
            )
            warnings.append(contentsOf: outcome.warnings)
            for warning in outcome.warnings {
                continuation.yield(.warning(warning.message))
            }
            guard outcome.rowsUpdated > 0 else { continue }
            continuation.yield(
                .secondPassFinished(
                    table: table.qualifiedName,
                    columns: table.deferredColumns,
                    rowsUpdated: outcome.rowsUpdated
                )
            )
        }
    }

    /// Replays the rows an earlier attempt already wrote and throws them away.
    /// This is what restores the deterministic stream: every column's generator,
    /// every unique tracker and every pool cursor ends up in the state it was in
    /// when the run was interrupted, so the resumed rows continue the sequence
    /// instead of repeating its start.
    private func fastForward(builder: RowBuilder, to firstRow: Int) throws {
        guard firstRow > 0 else { return }
        for index in 0 ..< firstRow {
            if index % Self.cancellationCheckInterval == 0 {
                try checkCancellation()
            }
            _ = try builder.buildRow(index: index)
        }
    }

    private var isCheckpointing: Bool {
        options.isResumable && !options.singleTransaction
    }

    private func resumePoints(plan: GenerationPlan) async -> [String: GenerationCheckpoint] {
        guard isCheckpointing else { return [:] }
        let entries = await checkpoints.load(jobId: GenerationCheckpointStore.jobId(for: plan))
        return Dictionary(entries.map { ($0.table, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    private func recordCheckpoint(plan: GenerationPlan, entry: GenerationCheckpoint) async {
        guard isCheckpointing else { return }
        await checkpoints.record(jobId: GenerationCheckpointStore.jobId(for: plan), entry: entry)
    }

    private func clearCheckpoints(plan: GenerationPlan) async {
        guard isCheckpointing else { return }
        await checkpoints.clear(jobId: GenerationCheckpointStore.jobId(for: plan))
    }

    /// The writer's per-batch hook. A checkpoint lands after the batch it counts
    /// was accepted, never before, so a resumed run can only ever re-generate
    /// rows the server refused.
    private func checkpointRecorder(
        plan: GenerationPlan,
        table: TablePlan
    ) -> (@Sendable (Int) async -> Void)? {
        guard isCheckpointing else { return nil }
        let store = checkpoints
        let jobId = GenerationCheckpointStore.jobId(for: plan)
        let name = table.qualifiedName
        return { rowsConsumed in
            await store.record(
                jobId: jobId,
                entry: GenerationCheckpoint(table: name, rowsWritten: rowsConsumed)
            )
        }
    }

    private static func skippedReport(table: TablePlan, startedAt: Date) -> GenerationTableReport {
        GenerationTableReport(
            table: table.qualifiedName,
            rowsRequested: table.rowCount,
            rowsWritten: table.rowCount,
            failedBatches: 0,
            duration: Date().timeIntervalSince(startedAt)
        )
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
        let binder = ReferencePoolBinder(
            strategy: options.referenceStrategy,
            values: { key in try await self.values(for: key) },
            queryValues: { source in
                try await self.driver.loadQueryValues(source: source, limit: self.options.referencePoolLimit)
            },
            onDegrade: { message in continuation.yield(.warning(message)) }
        )
        try await binder.bind(to: builder, table: table, runSeed: runSeed)
    }

    private func values(for key: ReferenceKey) async throws -> [[PluginCellValue]] {
        let reference = GenerationTableReference(schema: key.schema, table: key.table)
        if let keys = harvested[reference], let projected = keys.project(key.columns), !projected.isEmpty {
            return projected
        }
        return try await driver.loadDistinctValues(key: key, limit: options.referencePoolLimit)
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
        // A table with a deferred column has to find the rows it just wrote for
        // its own second pass, whether or not any other table points at it.
        if let owner = plan.tables.first(where: { $0.reference == table }), !owner.deferredColumns.isEmpty {
            for column in owner.primaryKeyColumns where !wanted.contains(column) {
                wanted.append(column)
            }
        }
        return wanted
    }
}
