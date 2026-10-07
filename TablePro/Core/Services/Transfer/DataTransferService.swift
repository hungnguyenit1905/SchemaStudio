//
//  DataTransferService.swift
//  TablePro
//

import Foundation
import Observation
import os
import TableProPluginKit

@MainActor @Observable
final class DataTransferService {
    static let logger = Logger(subsystem: "com.SchemaStudio", category: "DataTransferService")

    var state = TransferState()

    private(set) var isCancelled = false

    func cancel() {
        guard state.isTransferring else { return }
        isCancelled = true
        state.isCancelling = true
        state.statusMessage = String(localized: "Stopping after the current batch\u{2026}")
    }

    var shouldStop: Bool { isCancelled || Task.isCancelled }

    // MARK: - Public API

    func preview(
        selections: [TransferTableSelection],
        source: TransferEndpoint,
        target: TransferEndpoint,
        mode: TransferMode,
        options: TransferOptions
    ) async throws -> TransferPreview {
        try validate(selections: selections, source: source, target: target)
        try await ensureConnected(source)
        try await ensureConnected(target)

        return try await withDriverProvider(
            source: source,
            target: target,
            laneCount: Self.laneCount(for: options)
        ) { sourceContext, targetContext, _ in
            try await self.runPreflight(
                selections: selections,
                source: sourceContext,
                target: targetContext,
                mode: mode,
                options: options
            )
        }
    }

    func transfer(
        selections: [TransferTableSelection],
        source: TransferEndpoint,
        target: TransferEndpoint,
        mode: TransferMode,
        options: TransferOptions,
        resume: Bool = false
    ) async throws -> TransferReport {
        try validate(selections: selections, source: source, target: target)
        try await ensureConnected(source)
        try await ensureConnected(target)

        isCancelled = false
        state = TransferState(isTransferring: true, totalTables: selections.count)
        defer {
            state.isTransferring = false
            state.isCancelling = false
            state.statusMessage = ""
            isCancelled = false
        }

        let store = TransferCheckpointStore.shared
        let jobId = TransferCheckpointStore.jobId(source: source, target: target, mode: mode)

        do {
            return try await withDriverProvider(
                source: source,
                target: target,
                laneCount: Self.laneCount(for: options)
            ) { sourceContext, targetContext, lanes in
                self.state.statusMessage = String(localized: "Checking tables\u{2026}")
                let preview = try await self.runPreflight(
                    selections: selections,
                    source: sourceContext,
                    target: targetContext,
                    mode: mode,
                    options: options
                )
                guard preview.isClean || options.continueOnError else {
                    throw TransferError.preflightFailed(preview.failures)
                }
                let usesCheckpointJournal = Self.shouldUseCheckpointJournal(mode: mode, options: options)
                let journal = usesCheckpointJournal ? try await targetContext.transferCheckpointJournal() : nil
                if usesCheckpointJournal, journal == nil {
                    throw TransferError.resumeUnsupported(target.databaseType.displayName)
                }
                if !resume {
                    try await journal?.clear(jobId: jobId)
                    await store.clear(jobId: jobId)
                }
                let resumeState = try await Self.resolveResumeState(
                    resume: resume,
                    jobId: jobId,
                    store: store,
                    journal: journal,
                    selectedTables: Set(selections.map(\.table))
                )
                self.state.statusMessage = ""
                var consistency = TransferConsistency.perTable
                let report = try await self.runPhases(
                    selections: selections,
                    preview: preview,
                    source: sourceContext,
                    target: targetContext,
                    options: options,
                    resume: resumeState,
                    jobId: jobId,
                    journal: journal,
                    lanes: lanes,
                    consistency: &consistency
                )
                // A checkpoint is only cleared when the job finished without
                // failure or cancellation: an interrupted run leaves it for the
                // next launch to resume from.
                if Self.shouldClearCheckpoint(after: report) {
                    try await journal?.clear(jobId: jobId)
                    await store.clear(jobId: jobId)
                }
                return report
            }
        } catch {
            state.errorMessage = error.localizedDescription
            CrashReporterService.shared.capture(
                DiagnosticEventFactory.transferAborted(type: source.databaseType, error: error)
            )
            throw error
        }
    }

    static func shouldUseCheckpointJournal(mode: TransferMode, options: TransferOptions) -> Bool {
        mode == .emptyThenTransfer && !options.useSingleTransaction
    }

    static func shouldClearCheckpoint(after report: TransferReport) -> Bool {
        !report.wasCancelled && report.failedCount == 0 && report.notRunCount == 0 && report.mismatchedCounts.isEmpty
    }

    /// What a previous run of the same source/target/mode left behind, for the
    /// wizard to offer resuming before a new run starts.
    func pendingResume(
        source: TransferEndpoint,
        target: TransferEndpoint,
        mode: TransferMode,
        options: TransferOptions
    ) async throws -> TransferResumeState? {
        guard Self.shouldUseCheckpointJournal(mode: mode, options: options) else { return nil }
        let jobId = TransferCheckpointStore.jobId(source: source, target: target, mode: mode)
        try await ensureConnected(target)
        guard let driver = DatabaseManager.shared.driver(for: target.connectionId),
              let context = TransferDriverContext(driver: driver, endpoint: target),
              let journal = try await context.transferCheckpointJournal() else {
            return nil
        }
        guard let journalState = try await journal.load(jobId: jobId) else { return nil }
        let cache = TransferCheckpointStore.State(journalState)
        await TransferCheckpointStore.shared.cache(jobId: jobId, mode: mode, state: cache)
        return TransferResumeState(journalState)
    }

    private static func resolveResumeState(
        resume: Bool,
        jobId: UUID,
        store: TransferCheckpointStore,
        journal: (any PluginTransferCheckpointJournal)?,
        selectedTables: Set<String>
    ) async throws -> TransferResumeState? {
        guard resume else { return nil }
        guard let journal, let state = try await journal.load(jobId: jobId) else {
            throw TransferError.resumeStateUnavailable
        }
        let resumeState = try validateResumeState(state, jobId: jobId, selectedTables: selectedTables)
        await store.cache(jobId: jobId, mode: .emptyThenTransfer, state: TransferCheckpointStore.State(state))
        return resumeState
    }

    static func validateResumeState(
        _ state: PluginTransferCheckpointState,
        jobId: UUID,
        selectedTables: Set<String>
    ) throws -> TransferResumeState {
        guard state.manifest.sourceJobId == jobId,
              Set(state.manifest.tables.map(\.table)) == selectedTables else {
            throw TransferError.resumeStateUnavailable
        }
        return TransferResumeState(state)
    }

    // MARK: - Guards

    /// The service is the enforcement point, not the wizard: the sidebar opens
    /// the same run through a different path.
    func validate(
        selections: [TransferTableSelection],
        source: TransferEndpoint,
        target: TransferEndpoint
    ) throws {
        guard !selections.isEmpty else { throw TransferError.noTablesSelected }
        guard source.databaseType == target.databaseType else {
            throw TransferError.differentDatabaseTypes(
                source: source.databaseType.displayName,
                target: target.databaseType.displayName
            )
        }
        guard source.scope != target.scope else { throw TransferError.sameEndpoint }
        guard !safeModeLevel(for: target.connectionId).blocksAllWrites else {
            throw TransferError.targetIsReadOnly
        }
    }

    func safeModeLevel(for connectionId: UUID) -> SafeModeLevel {
        if let session = DatabaseManager.shared.session(for: connectionId) {
            return session.safeModeLevel
        }
        return storedConnection(connectionId)?.safeModeLevel ?? .silent
    }

    private func storedConnection(_ connectionId: UUID) -> DatabaseConnection? {
        ConnectionStorage.shared.loadConnections().first { $0.id == connectionId }
    }

    private func ensureConnected(_ endpoint: TransferEndpoint) async throws {
        if DatabaseManager.shared.session(for: endpoint.connectionId)?.driver != nil { return }
        guard let connection = storedConnection(endpoint.connectionId) else {
            throw DatabaseError.notConnected
        }
        try await DatabaseManager.shared.connectToSession(connection)
    }

    // MARK: - Drivers

    /// Both drivers come from the bulk lane of the pool so a long copy never
    /// queues behind, or ahead of, the metadata queries the user's own
    /// browsing depends on. The pool serializes per scope, so the two scopes
    /// have to differ before the nesting is safe.
    ///
    /// Lane 0 is the pair held for the whole run. `TransferLanePool` opens the
    /// higher lanes through the same pool, each capped by the pool's connection
    /// budget, so parallel tables never starve the interactive lanes.
    private func withDriverProvider<T: Sendable>(
        source: TransferEndpoint,
        target: TransferEndpoint,
        laneCount: Int,
        body: @escaping @Sendable @MainActor (
            TransferDriverContext,
            TransferDriverContext,
            TransferLanePool
        ) async throws -> T
    ) async throws -> T {
        let pool = MetadataConnectionPool.shared
        let configuredTimeout = AppSettingsManager.shared.general.queryTimeoutSeconds
        return try await pool.withDriver(scope: target.scope, workload: .bulk, lane: 0) { targetDriver in
            try await pool.withDriver(scope: source.scope, workload: .bulk, lane: 0) { sourceDriver in
                guard let sourceContext = TransferDriverContext(driver: sourceDriver, endpoint: source),
                      let targetContext = TransferDriverContext(driver: targetDriver, endpoint: target) else {
                    throw TransferError.noPluginDriver
                }

                await sourceContext.applyQueryTimeout(0)
                await targetContext.applyQueryTimeout(0)

                let lanes = TransferLanePool(
                    source: source,
                    target: target,
                    laneCount: laneCount,
                    restoreTimeout: configuredTimeout
                )

                do {
                    let result = try await body(sourceContext, targetContext, lanes)
                    await sourceContext.applyQueryTimeout(configuredTimeout)
                    await targetContext.applyQueryTimeout(configuredTimeout)
                    return result
                } catch {
                    await sourceContext.applyQueryTimeout(configuredTimeout)
                    await targetContext.applyQueryTimeout(configuredTimeout)
                    throw error
                }
            }
        }
    }

    /// One lane per parallel table and one per partition come out of the same
    /// budget, so the allocator is sized for whichever dimension asks for more.
    private static func laneCount(for options: TransferOptions) -> Int {
        MetadataConnectionPool.cappedParallelism(
            max(options.parallelTables, options.inTableParallelism)
        )
    }
}
