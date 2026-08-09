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

    static let batchRowCount = 1_000

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

        return try await withEndpointDrivers(source: source, target: target) { sourceContext, targetContext in
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
        options: TransferOptions
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

        do {
            return try await withEndpointDrivers(source: source, target: target) { sourceContext, targetContext in
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
                return try await self.runPhases(
                    selections: selections,
                    preview: preview,
                    source: sourceContext,
                    target: targetContext,
                    options: options
                )
            }
        } catch {
            state.errorMessage = error.localizedDescription
            throw error
        }
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
    private func withEndpointDrivers<T: Sendable>(
        source: TransferEndpoint,
        target: TransferEndpoint,
        body: @escaping @Sendable @MainActor (TransferDriverContext, TransferDriverContext) async throws -> T
    ) async throws -> T {
        let pool = MetadataConnectionPool.shared
        return try await pool.withDriver(scope: target.scope, workload: .bulk) { targetDriver in
            try await pool.withDriver(scope: source.scope, workload: .bulk) { sourceDriver in
                try await Self.runWithDrivers(
                    sourceDriver: sourceDriver,
                    targetDriver: targetDriver,
                    source: source,
                    target: target,
                    body: body
                )
            }
        }
    }

    /// The pool stamps its own drivers with the user's query timeout, which
    /// would cut any table that takes longer than one minute to copy. The
    /// driver outlives this run inside the pool, so the setting has to go back
    /// on both success and failure.
    @MainActor
    private static func runWithDrivers<T: Sendable>(
        sourceDriver: DatabaseDriver,
        targetDriver: DatabaseDriver,
        source: TransferEndpoint,
        target: TransferEndpoint,
        body: @escaping @Sendable @MainActor (TransferDriverContext, TransferDriverContext) async throws -> T
    ) async throws -> T {
        guard let sourceContext = TransferDriverContext(driver: sourceDriver, endpoint: source),
              let targetContext = TransferDriverContext(driver: targetDriver, endpoint: target) else {
            throw TransferError.noPluginDriver
        }

        let configuredTimeout = AppSettingsManager.shared.general.queryTimeoutSeconds
        await sourceContext.applyQueryTimeout(0)
        await targetContext.applyQueryTimeout(0)

        do {
            let result = try await body(sourceContext, targetContext)
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
