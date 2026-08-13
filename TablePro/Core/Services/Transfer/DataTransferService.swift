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

        return try await withDriverProvider(source: source, target: target) { sourceContext, targetContext, _ in
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
        // A run that was told to start over drops whatever the previous run
        // left behind; a run that resumes reads it instead.
        if !resume {
            await store.clear(jobId: jobId)
        }
        let resumeState = await Self.resolveResumeState(
            resume: resume,
            jobId: jobId,
            store: store
        )

        do {
            return try await withDriverProvider(source: source, target: target) { sourceContext, targetContext, provider in
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
                    provider: provider,
                    consistency: &consistency
                )
                // A checkpoint is only cleared when the job finished without
                // failure or cancellation: an interrupted run leaves it for the
                // next launch to resume from.
                if !report.wasCancelled, report.failedCount == 0, report.notRunCount == 0 {
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

    /// What a previous run of the same source/target/mode left behind, for the
    /// wizard to offer resuming before a new run starts.
    func pendingResume(
        source: TransferEndpoint,
        target: TransferEndpoint,
        mode: TransferMode
    ) async -> TransferResumeState? {
        guard mode == .emptyThenTransfer else { return nil }
        let store = TransferCheckpointStore.shared
        let entries = await store.load(
            jobId: TransferCheckpointStore.jobId(source: source, target: target, mode: mode)
        )
        return entries.isEmpty ? nil : TransferResumeState(entries: entries)
    }

    private static func resolveResumeState(
        resume: Bool,
        jobId: UUID,
        store: TransferCheckpointStore
    ) async -> TransferResumeState? {
        guard resume else { return nil }
        let entries = await store.load(jobId: jobId)
        return entries.isEmpty ? nil : TransferResumeState(entries: entries)
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
    /// Lane 0 is the pair held for the whole run. Higher lanes open their own
    /// connections through the same pool, each capped by the pool's connection
    /// budget, so parallel tables never starve the interactive lanes; their
    /// query timeout is lifted for the duration and restored on the way out.
    private func withDriverProvider<T: Sendable>(
        source: TransferEndpoint,
        target: TransferEndpoint,
        body: @escaping @Sendable @MainActor (
            TransferDriverContext,
            TransferDriverContext,
            TransferDriverProvider
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

                let provider = TransferDriverProvider { lane in
                    guard lane > 0 else { return (sourceContext, targetContext) }
                    return try await pool.withDriver(scope: target.scope, workload: .bulk, lane: lane) { laneTargetDriver in
                        try await pool.withDriver(scope: source.scope, workload: .bulk, lane: lane) { laneSourceDriver in
                            guard let laneSource = TransferDriverContext(driver: laneSourceDriver, endpoint: source),
                                  let laneTarget = TransferDriverContext(driver: laneTargetDriver, endpoint: target) else {
                                throw TransferError.noPluginDriver
                            }
                            await laneSource.applyQueryTimeout(0)
                            await laneTarget.applyQueryTimeout(0)
                            return try await Self.withTimeoutRestore(
                                source: laneSource,
                                target: laneTarget,
                                timeout: configuredTimeout
                            ) {
                                (laneSource, laneTarget)
                            }
                        }
                    }
                }

                do {
                    let result = try await body(sourceContext, targetContext, provider)
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

    /// The pool stamps its own drivers with the user's query timeout, which
    /// would cut any table that takes longer than one minute to copy. A lane
    /// driver outlives this run inside the pool, so the setting has to go back
    /// on both success and failure.
    private static func withTimeoutRestore<T: Sendable>(
        source: TransferDriverContext,
        target: TransferDriverContext,
        timeout: Int,
        body: @Sendable () async throws -> T
    ) async throws -> T {
        do {
            let result = try await body()
            await source.applyQueryTimeout(timeout)
            await target.applyQueryTimeout(timeout)
            return result
        } catch {
            await source.applyQueryTimeout(timeout)
            await target.applyQueryTimeout(timeout)
            throw error
        }
    }
}
