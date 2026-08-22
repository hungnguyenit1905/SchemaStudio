//
//  DuplicateTableService.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct DuplicateResult: Sendable, Hashable {
    let target: DuplicateTableRef
    let warnings: [DuplicateWarning]
    let executedStatements: [String]
}

/// The app singletons the service needs, injected so the orchestration is testable without a
/// running app. Production wiring supplies the execution gate, the query history and the refresh
/// broadcast.
struct DuplicateServiceHooks: Sendable {
    var authorize: @Sendable () async throws -> Void = {}
    var recordHistory: @Sendable (_ stage: String, _ sql: String, _ succeeded: Bool, _ error: String?) -> Void
        = { _, _, _, _ in }
    var didFinish: @Sendable (DuplicateResult) -> Void = { _ in }
}

/// Order matters here and each step exists for a reason the tests name:
///
/// 1. Read the source and check the filter and the permissions before anything is created.
/// 2. Authorize **outside** any driver lease, because the prompt can wait on a person and holding
///    a lease across that freezes the connection's other tabs.
/// 3. Re-read the source structure, because step 2 is a human-paced gap during which another tab
///    can alter it, and the server-side `LIKE` would then disagree with the column list the copy
///    statement was built from.
struct DuplicateTableService: Sendable {
    let databaseType: DatabaseType
    let session: any DuplicateSessionProviding
    var hooks = DuplicateServiceHooks()

    func run(
        _ request: DuplicateTableRequest,
        token: DuplicateCancellationToken = DuplicateCancellationToken(),
        onProgress: @escaping @Sendable (DuplicateProgress) -> Void = { _ in }
    ) async throws -> DuplicateResult {
        guard let builder = DuplicatePlanBuilder.builder(for: databaseType) else {
            throw DuplicateError.unsupportedDatabase(databaseType.rawValue)
        }

        try validateRowFilterText(request)

        let introspection = try await session.withDriver(tracksCancellation: false) { driver in
            let introspection = try await DuplicateIntrospector(driver: driver).introspect(request.source)
            try await DuplicatePreflight(driver: driver).check(request, introspection: introspection)
            return introspection
        }

        try await runFilterValidation(request, builder: builder, introspection: introspection)

        try await hooks.authorize()

        return try await session.withDriver(tracksCancellation: true) { driver in
            try await execute(
                request,
                builder: builder,
                introspection: introspection,
                driver: driver,
                token: token,
                onProgress: onProgress
            )
        }
    }

    // MARK: - Row filter

    /// The primary defense, and it runs before a plan is even built. `EXPLAIN` proves the filter
    /// parses; it does not prove the filter is a single expression.
    private func validateRowFilterText(_ request: DuplicateTableRequest) throws {
        guard let filter = request.options.rowFilter?.trimmingCharacters(in: .whitespacesAndNewlines),
              !filter.isEmpty else { return }
        guard SQLBoundaryValidator.isRawFilterConditionSafe(filter) else {
            throw DuplicateError.unsafeRowFilter
        }
    }

    private func runFilterValidation(
        _ request: DuplicateTableRequest,
        builder: any DuplicatePlanBuilding,
        introspection: DuplicateTableIntrospection
    ) async throws {
        try await session.withDriver(tracksCancellation: true) { driver in
            let plan = builder.plan(request: request, introspection: introspection, quoting: driver.quoting)
            let validations = plan.statements.filter { $0.kind == .validateRowFilter }
            for statement in validations {
                guard case .sql(let sql) = statement.body else { continue }
                do {
                    _ = try await driver.run(statement, sql: sql)
                } catch {
                    throw DuplicateError.invalidRowFilter(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Execution

    private func execute(
        _ request: DuplicateTableRequest,
        builder: any DuplicatePlanBuilding,
        introspection: DuplicateTableIntrospection,
        driver: any DuplicateDriving,
        token: DuplicateCancellationToken,
        onProgress: @escaping @Sendable (DuplicateProgress) -> Void
    ) async throws -> DuplicateResult {
        let fresh = try await driver.fetchColumns(table: request.source.name, schema: request.source.schema)
        guard DuplicateStructureFingerprint.matches(introspection.columns, fresh) else {
            throw DuplicateError.sourceChangedDuringSetup
        }

        let plan = builder.plan(request: request, introspection: introspection, quoting: driver.quoting)
        guard !plan.isBlocked else {
            throw DuplicateError.partitionedSource(request.source.name)
        }

        let transactional = driver.supportsTransactionalDDL && plan.copyMode != .chunked
        if transactional {
            try await driver.begin()
        }

        let executor = DuplicateExecutor(driver: driver, token: token, onProgress: onProgress)
        do {
            // The validation statement already ran before authorization; running it again would
            // charge the user for the same EXPLAIN twice.
            let executable = DuplicatePlan(
                statements: plan.statements.filter { $0.kind != .validateRowFilter },
                warnings: plan.warnings,
                copyMode: plan.copyMode,
                estimatedRowCount: plan.estimatedRowCount
            )
            let outcome = try await executor.run(executable)
            if transactional {
                try await driver.commit()
            }
            hooks.recordHistory(
                Self.stageName,
                outcome.executedStatements.joined(separator: ";\n"),
                true,
                nil
            )
            let result = DuplicateResult(
                target: request.target,
                warnings: plan.warnings + outcome.warnings,
                executedStatements: outcome.executedStatements
            )
            hooks.didFinish(result)
            return result
        } catch {
            hooks.recordHistory(Self.stageName, "", false, error.localizedDescription)
            try await recover(
                request,
                plan: plan,
                driver: driver,
                transactional: transactional,
                originalError: error
            )
            throw error
        }
    }

    /// One history entry per run, not per statement. Chunked mode issues one statement per batch,
    /// so a per-statement entry would write hundreds of rows and fire as many main-actor
    /// notifications for a single user action.
    private static let stageName = "Duplicate table"

    private func recover(
        _ request: DuplicateTableRequest,
        plan: DuplicatePlan,
        driver: any DuplicateDriving,
        transactional: Bool,
        originalError: some Error
    ) async throws {
        let action = DuplicateRecovery.action(
            supportsTransactionalDDL: transactional,
            copyMode: plan.copyMode,
            hasCommittedRows: false
        )
        switch action {
        case .rollback:
            // Sent even when the transaction is already aborted: a connection returned to the
            // pool mid-transaction is unusable for whoever picks it up next.
            try? await driver.rollback()
        case .dropTarget, .askBeforeDropping:
            let statement = DuplicateRecovery.dropStatement(target: request.target, quoting: driver.quoting)
            guard case .sql(let sql) = statement.body else { return }
            do {
                _ = try await driver.run(statement, sql: sql)
            } catch {
                throw DuplicateError.cleanupFailed(
                    target: request.targetName,
                    command: sql,
                    serverMessage: originalError.localizedDescription
                )
            }
        }
    }
}
