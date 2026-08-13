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
        options: TransferOptions,
        resume: TransferResumeState?,
        jobId: UUID,
        provider: TransferDriverProvider?,
        consistency: inout TransferConsistency
    ) async throws -> TransferReport {
        var run = TransferRunState()
        for failure in preview.failures {
            run.fail(failure.table, message: failure.message)
        }

        let estimates = await estimatedRowCounts(for: preview.plans, source: source)

        await runStructurePhase(preview.plans, target: target, options: options, run: &run, resume: resume)
        consistency = try await runDataPhase(
            preview.plans,
            source: source,
            target: target,
            options: options,
            estimates: estimates,
            limits: preview.targetCapabilities.limits,
            resume: resume,
            jobId: jobId,
            provider: provider,
            run: &run
        )
        await runConstraintPhase(preview.plans, target: target, run: &run, resume: resume)

        let counts = await verifyCounts(plans: preview.plans, source: source, target: target)
        return run.report(for: selections, counts: counts, consistency: consistency)
    }

    /// A TRUNCATE or DROP of a table another table points at is refused while
    /// the engine enforces its foreign keys (MySQL 1701 and 3730). The pass
    /// visits tables in an arbitrary order, so a parent is always reachable
    /// before its children are gone: the whole pass runs with the checks off.
    func runStructurePhase(
        _ plans: [TransferTablePlan],
        target: TransferDriverContext,
        options: TransferOptions,
        run: inout TransferRunState,
        resume: TransferResumeState? = nil
    ) async {
        state.statusMessage = String(localized: "Preparing target tables\u{2026}")
        let foreignKeysDisabled = await disableForeignKeyChecks(on: target)
        await applyStructurePlans(plans, target: target, options: options, run: &run, resume: resume)
        if foreignKeysDisabled {
            await restoreForeignKeyChecks(on: target)
        }
        state.statusMessage = ""
    }

    private func applyStructurePlans(
        _ plans: [TransferTablePlan],
        target: TransferDriverContext,
        options: TransferOptions,
        run: inout TransferRunState,
        resume: TransferResumeState?
    ) async {
        for plan in plans where !run.isBlocked(plan.table) {
            if run.stopped || shouldStop {
                run.stopped = true
                return
            }
            // A table with checkpoint progress already exists at the target
            // with committed rows in it. Dropping, truncating or recreating it
            // would destroy that progress, so a resumed run skips its
            // structure steps entirely.
            guard !(resume?.hasProgress(table: plan.table) ?? false) else { continue }
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

    // MARK: - Data Phase

    private func runDataPhase(
        _ plans: [TransferTablePlan],
        source: TransferDriverContext,
        target: TransferDriverContext,
        options: TransferOptions,
        estimates: [String: Int],
        limits: PluginServerLimits?,
        resume: TransferResumeState?,
        jobId: UUID,
        provider: TransferDriverProvider?,
        run: inout TransferRunState
    ) async throws -> TransferConsistency {
        let transferable = plans.filter { $0.steps.contains(.transferRows) }
        state.totalTables = transferable.count
        let lanes = provider != nil ? MetadataConnectionPool.cappedParallelism(options.parallelTables) : 1

        // PostgreSQL pins one snapshot for the whole data phase, so every
        // chunk and every lane reads the same point in time. The transaction
        // is released when the phase ends, before the driver goes back to the
        // pool. Other engines have no exportable snapshot and report the
        // weaker, honest level instead.
        let snapshotToken = source.databaseType == .postgresql ? try? await source.exportSnapshotToken() : nil
        defer {
            if snapshotToken != nil {
                Task { @MainActor in
                    try? await source.execute("ROLLBACK")
                }
            }
        }

        var tableIndex = markCompleteTables(transferable, resume: resume, run: &run)
        let gate = TransferRunGate()

        let context = TransferCopyContext(
            resume: resume,
            jobId: jobId,
            checkpoint: TransferCheckpointStore.shared,
            snapshotToken: snapshotToken,
            gate: gate,
            provider: provider
        )

        if lanes > 1, let provider {
            try await withThrowingTaskGroup(of: TransferTableCopyResult.self) { group in
                var lane = 0
                for plan in transferable where !run.isBlocked(plan.table) && !(resume?.isComplete(table: plan.table) ?? false) {
                    let currentLane = lane % lanes
                    lane += 1
                    group.addTask { @MainActor in
                        if gate.stopped || self.shouldStop {
                            return TransferTableCopyResult.skipped(plan.table)
                        }
                        let pair = try await provider.pair(lane: currentLane)
                        if currentLane > 0, let snapshotToken {
                            let adopted = (try? await pair.source.adoptSnapshotToken(snapshotToken)) ?? false
                            if !adopted {
                                gate.downgradeConsistency()
                            }
                        }
                        defer {
                            if currentLane > 0 {
                                Task { @MainActor in try? await pair.source.execute("ROLLBACK") }
                            }
                        }
                        return await self.copyTableForRun(
                            plan: plan,
                            source: pair.source,
                            target: pair.target,
                            options: options,
                            limits: limits,
                            context: context
                        )
                    }
                }
                for try await result in group {
                    // Lanes finish in whatever order the servers answer, so the
                    // count advances per completed table rather than naming the
                    // one table a parallel run is on.
                    if !result.skipped {
                        tableIndex += 1
                        state.currentTable = result.table
                        state.currentTableIndex = tableIndex
                    }
                    self.mergeCopyResult(result, run: &run, options: options, target: target, gate: gate)
                    if run.stopped { group.cancelAll() }
                }
            }
        } else {
            for plan in transferable where !run.isBlocked(plan.table) && !(resume?.isComplete(table: plan.table) ?? false) {
                if run.stopped || shouldStop {
                    run.stopped = true
                    return snapshotToken != nil && gate.isDatabaseWide ? .databaseWide : .perTable
                }
                tableIndex += 1
                beginTableProgress(plan.table, index: tableIndex, estimates: estimates)
                let result = await copyTableForRun(
                    plan: plan,
                    source: source,
                    target: target,
                    options: options,
                    limits: limits,
                    context: context
                )
                mergeCopyResult(result, run: &run, options: options, target: target, gate: gate)
                if run.stopped { return snapshotToken != nil && gate.isDatabaseWide ? .databaseWide : .perTable }
            }
        }
        if shouldStop { run.stopped = true }
        return snapshotToken != nil && gate.isDatabaseWide ? .databaseWide : .perTable
    }

    /// Tables whose checkpoint already marks the data phase complete are
    /// counted as succeeded without touching the source or the target again.
    /// Returns how many tables the count already covers, so the tables still to
    /// copy carry on from there.
    private func markCompleteTables(
        _ transferable: [TransferTablePlan],
        resume: TransferResumeState?,
        run: inout TransferRunState
    ) -> Int {
        var index = 0
        for plan in transferable where resume?.isComplete(table: plan.table) == true {
            index += 1
            state.currentTable = plan.table
            state.currentTableIndex = index
            run.succeed(plan.table, rows: resume?.rowsDone(table: plan.table) ?? 0, duration: 0)
        }
        return index
    }

    /// The estimate is the denominator of this table alone, so a table the
    /// driver could not estimate leaves the fraction at zero rather than
    /// dividing by a number from another table.
    private func beginTableProgress(_ table: String, index: Int, estimates: [String: Int]) {
        state.currentTable = table
        state.currentTableIndex = index
        state.currentTableProcessedRows = 0
        state.currentTableEstimatedRows = estimates[table] ?? 0
    }

    private func copyTableForRun(
        plan: TransferTablePlan,
        source: TransferDriverContext,
        target: TransferDriverContext,
        options: TransferOptions,
        limits: PluginServerLimits?,
        context: TransferCopyContext
    ) async -> TransferTableCopyResult {
        let startedAt = Date()
        do {
            let rows: Int
            if let boundaries = try await partitionBoundaries(
                plan: plan,
                source: source,
                options: options
            ), !boundaries.isEmpty, let provider = context.provider {
                rows = try await copyTablePartitioned(
                    plan: plan,
                    boundaries: boundaries,
                    options: options,
                    limits: limits,
                    context: context
                )
            } else {
                rows = try await copyRows(
                    plan: plan,
                    source: source,
                    target: target,
                    options: options,
                    limits: limits,
                    checkpoint: context.checkpoint,
                    jobId: context.jobId,
                    resumeCursor: context.resume?.entry(table: plan.table)?.cursor
                )
            }
            return TransferTableCopyResult(
                table: plan.table,
                rows: rows,
                duration: Date().timeIntervalSince(startedAt),
                error: nil,
                startedAt: startedAt
            )
        } catch {
            return TransferTableCopyResult(
                table: plan.table,
                rows: 0,
                duration: Date().timeIntervalSince(startedAt),
                error: error,
                startedAt: startedAt
            )
        }
    }

    /// Splits one table into parallel ranges when its single numeric primary
    /// key is large enough that a full index scan for the boundaries pays for
    /// itself. UUID, composite and unknown-size keys stay sequential.
    private func partitionBoundaries(
        plan: TransferTablePlan,
        source: TransferDriverContext,
        options: TransferOptions
    ) async throws -> [String]? {
        guard options.inTableParallelism > 1,
              plan.structure.primaryKeyColumns.count == 1 else { return nil }
        let column = plan.structure.primaryKeyColumns[0]
        guard TransferParallelism.shouldParallelize(
            estimatedRows: try? await source.approximateRowCount(table: plan.table),
            threshold: Self.inTableParallelThreshold
        ) else { return nil }
        let partitions = MetadataConnectionPool.cappedParallelism(options.inTableParallelism)
        return try await source.primaryKeyRangeBoundaries(
            table: plan.table,
            column: column,
            partitions: partitions
        )
    }

    /// Runs one table as several keyset partitions, each on its own driver
    /// pair, starting at the previous partition's boundary. Partition 0 reads
    /// up to the first boundary; the last partition reads to the end of the
    /// table. Every partition checkpoint carries its own index, so a resume
    /// restores each range separately.
    private func copyTablePartitioned(
        plan: TransferTablePlan,
        boundaries: [String],
        options: TransferOptions,
        limits: PluginServerLimits?,
        context: TransferCopyContext
    ) async throws -> Int {
        let partitionCount = boundaries.count + 1
        guard let provider = context.provider else { return 0 }
        return try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0 ..< partitionCount {
                let upperBound = index < boundaries.count ? boundaries[index] : nil
                let lowerBound = index > 0 ? boundaries[index - 1] : nil
                let resumeCursor = context.resume?.entry(table: plan.table, partition: index)?.cursor
                    ?? lowerBound.map { TransferChunkCursor(lastKey: [$0], rowsDone: 0) }
                group.addTask { @MainActor in
                    // Partition lanes start at 1: lane 0 is the run's own pair.
                    let pair = try await provider.pair(lane: index + 1)
                    if let snapshotToken = context.snapshotToken {
                        let adopted = (try? await pair.source.adoptSnapshotToken(snapshotToken)) ?? false
                        if !adopted { context.gate.downgradeConsistency() }
                    }
                    defer {
                        Task { @MainActor in try? await pair.source.execute("ROLLBACK") }
                    }
                    return try await self.copyRows(
                        plan: plan,
                        source: pair.source,
                        target: pair.target,
                        options: options,
                        limits: limits,
                        checkpoint: context.checkpoint,
                        jobId: context.jobId,
                        resumeCursor: resumeCursor,
                        partition: index,
                        upperBound: upperBound
                    )
                }
            }
            var total = 0
            for try await written in group {
                total += written
            }
            return total
        }
    }

    private func mergeCopyResult(
        _ result: TransferTableCopyResult,
        run: inout TransferRunState,
        options: TransferOptions,
        target: TransferDriverContext,
        gate: TransferRunGate
    ) {
        if result.skipped { return }
        if let error = result.error {
            if error is CancellationError {
                return
            }
            run.fail(result.table, message: error.localizedDescription, duration: result.duration)
            recordHistory(
                table: result.table,
                rows: 0,
                target: target,
                startedAt: result.startedAt,
                error: error
            )
            if !options.continueOnError {
                run.stopped = true
                gate.stop()
            }
        } else {
            run.succeed(result.table, rows: result.rows, duration: result.duration)
            recordHistory(
                table: result.table,
                rows: result.rows,
                target: target,
                startedAt: result.startedAt,
                error: nil
            )
        }
    }

    // MARK: - Constraint Phase

    /// `ALTER TABLE ... ADD CONSTRAINT FOREIGN KEY` validates every row already
    /// in the table, so a source that holds an orphan row aborts the statement
    /// (MySQL 1452). The transfer mirrors the source, the way `mysqldump` does,
    /// so the whole pass runs with the checks off.
    func runConstraintPhase(
        _ plans: [TransferTablePlan],
        target: TransferDriverContext,
        run: inout TransferRunState,
        resume: TransferResumeState? = nil
    ) async {
        guard !run.stopped else { return }
        state.statusMessage = String(localized: "Adding indexes and foreign keys\u{2026}")
        defer { state.statusMessage = "" }

        let foreignKeysDisabled = await disableForeignKeyChecks(on: target)
        await applyConstraintPlans(plans, target: target, run: &run, resume: resume)
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
        run: inout TransferRunState,
        resume: TransferResumeState?
    ) async {
        for plan in plans where !run.isBlocked(plan.table) {
            if shouldStop {
                run.stopped = true
                return
            }
            let messages = await applyConstraintSteps(plan, target: target, resume: resume)
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
        target: TransferDriverContext,
        resume: TransferResumeState?
    ) async -> [String] {
        var messages: [String] = []
        // Only tables with committed progress can collide with objects the
        // previous run created before it crashed.
        let tolerateExisting = resume?.hasProgress(table: plan.table) == true

        for step in plan.steps {
            switch step {
            case .createIndexes:
                for index in plan.structure.indexes {
                    guard let sql = target.addIndexStatement(table: plan.table, index: index) else { continue }
                    await appendConstraintFailure(
                        of: sql,
                        on: target,
                        table: plan.table,
                        tolerateExisting: tolerateExisting,
                        to: &messages
                    )
                }
            case .createForeignKeys:
                for foreignKey in plan.structure.foreignKeys {
                    guard let sql = target.addForeignKeyStatement(table: plan.table, foreignKey: foreignKey) else {
                        continue
                    }
                    await appendConstraintFailure(
                        of: sql,
                        on: target,
                        table: plan.table,
                        tolerateExisting: tolerateExisting,
                        to: &messages
                    )
                }
            case .resetSequences:
                for column in plan.structure.autoIncrementColumns {
                    guard let sql = target.resetSequenceStatement(table: plan.table, column: column) else { continue }
                    await appendConstraintFailure(
                        of: sql,
                        on: target,
                        table: plan.table,
                        tolerateExisting: tolerateExisting,
                        to: &messages
                    )
                }
            case .dropTargetTable, .dropTargetTypes, .createTargetTypes, .createTargetTable,
                 .truncateTarget, .transferRows, .failMissingTarget:
                continue
            }
        }

        return messages
    }

    private func appendConstraintFailure(
        of statement: String,
        on target: TransferDriverContext,
        table: String,
        tolerateExisting: Bool,
        to messages: inout [String]
    ) async {
        do {
            try await runConstraintStatement(
                statement,
                target: target,
                table: table,
                tolerateExisting: tolerateExisting
            )
        } catch {
            messages.append(error.localizedDescription)
            Self.logger.warning(
                "Transfer constraint statement failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// An index or foreign key a previous run created before it crashed is a
    /// duplicate on re-run, not a failure: a resumed run skips what is already
    /// there and reports it instead of failing the table.
    private func runConstraintStatement(
        _ sql: String,
        target: TransferDriverContext,
        table: String,
        tolerateExisting: Bool
    ) async throws {
        do {
            try await target.execute(sql)
        } catch {
            guard tolerateExisting, TransferErrorClassifier.isDuplicateObject(error) else { throw error }
            Self.logger.info(
                "Constraint already exists on \(table, privacy: .public), skipping: \(error.localizedDescription, privacy: .public)"
            )
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

// MARK: - Row Copy Support Types

/// Hands out the driver pairs the data phase copies tables with. Lane 0 is the
/// pair the run already holds; higher lanes open their own connections through
/// the metadata pool, capped by the pool's connection budget.
struct TransferDriverProvider: Sendable {
    private let call: @Sendable (Int) async throws -> (source: TransferDriverContext, target: TransferDriverContext)

    init(call: @escaping @Sendable (Int) async throws -> (source: TransferDriverContext, target: TransferDriverContext)) {
        self.call = call
    }

    func pair(lane: Int) async throws -> (source: TransferDriverContext, target: TransferDriverContext) {
        try await call(lane)
    }
}

/// Everything a table copy needs that is not the pair of drivers it runs on.
private struct TransferCopyContext {
    let resume: TransferResumeState?
    let jobId: UUID
    let checkpoint: TransferCheckpointStore
    let snapshotToken: String?
    let gate: TransferRunGate
    let provider: TransferDriverProvider?
}

@MainActor
private final class TransferRunGate {
    private(set) var stopped = false
    private(set) var isDatabaseWide = true

    func stop() {
        stopped = true
    }

    func downgradeConsistency() {
        isDatabaseWide = false
    }
}

private struct TransferTableCopyResult: Sendable {
    let table: String
    let rows: Int
    let duration: TimeInterval
    let error: Error?
    let startedAt: Date
    let skipped: Bool

    init(table: String, rows: Int, duration: TimeInterval, error: Error?, startedAt: Date) {
        self.table = table
        self.rows = rows
        self.duration = duration
        self.error = error
        self.startedAt = startedAt
        skipped = false
    }

    static func skipped(_ table: String) -> TransferTableCopyResult {
        TransferTableCopyResult(
            table: table,
            rows: 0,
            duration: 0,
            error: nil,
            startedAt: Date()
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

    func report(
        for selections: [TransferTableSelection],
        counts: [String: (source: Int, target: Int)] = [:],
        consistency: TransferConsistency = .perTable
    ) -> TransferReport {
        let results = selections.map { selection -> TransferTableResult in
            TransferTableResult(
                table: selection.table,
                rowsTransferred: rows[selection.table] ?? 0,
                duration: durations[selection.table] ?? 0,
                outcome: outcome(for: selection.table),
                sourceCount: counts[selection.table]?.source,
                targetCount: counts[selection.table]?.target
            )
        }
        return TransferReport(results: results, wasCancelled: stopped, consistency: consistency)
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

enum TransferBatchSizing {
    static let defaultMaxBytes = 4 * 1_048_576
    static let safetyMargin = 64 * 1_024
}
