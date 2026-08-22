//
//  DuplicateExecutor.swift
//  TablePro
//

import Foundation

final class DuplicateCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

struct DuplicateProgress: Sendable, Hashable {
    let step: Int
    /// Grows once the index harvest reports how many indexes there are, so the UI must not treat
    /// the first value it sees as final.
    let totalSteps: Int
    let kind: DuplicateStatement.Kind
}

struct DuplicateExecutionOutcome: Sendable, Hashable {
    let executedStatements: [String]
    let warnings: [DuplicateWarning]
}

/// Walks a plan against one driver. Two things happen here that cannot happen in the builder:
/// deferred statements become real ones once the harvest has run, and a failure is judged against
/// the statement's severity instead of aborting everything.
struct DuplicateExecutor: Sendable {
    let driver: any DuplicateDriving
    let token: DuplicateCancellationToken
    let onProgress: @Sendable (DuplicateProgress) -> Void

    init(
        driver: any DuplicateDriving,
        token: DuplicateCancellationToken = DuplicateCancellationToken(),
        onProgress: @escaping @Sendable (DuplicateProgress) -> Void = { _ in }
    ) {
        self.driver = driver
        self.token = token
        self.onProgress = onProgress
    }

    func run(_ plan: DuplicatePlan) async throws -> DuplicateExecutionOutcome {
        var harvested: [HarvestedIndex] = []
        var executed: [String] = []
        var warnings: [DuplicateWarning] = []
        var step = 0
        var total = plan.statements.count

        for statement in plan.statements {
            try checkCancellation()

            switch statement.body {
            case .sql(let sql):
                step += 1
                onProgress(DuplicateProgress(step: step, totalSteps: total, kind: statement.kind))
                let rows = try await perform(statement, sql: sql, executed: &executed, warnings: &warnings)
                if statement.kind == .harvestIndexes {
                    harvested = Self.harvestedIndexes(from: rows)
                    // Each deferred placeholder stands in for one statement per harvested index.
                    total += harvested.count * 2 - 2
                }

            case .deferred(.fromHarvestedIndexes):
                for index in harvested {
                    try checkCancellation()
                    step += 1
                    onProgress(DuplicateProgress(step: step, totalSteps: total, kind: statement.kind))
                    let sql = Self.deferredSQL(for: statement.kind, index: index)
                    guard let sql else { continue }
                    _ = try await perform(statement, sql: sql, executed: &executed, warnings: &warnings)
                }
            }
        }

        return DuplicateExecutionOutcome(executedStatements: executed, warnings: warnings)
    }

    // MARK: - Statement execution

    private func perform(
        _ statement: DuplicateStatement,
        sql: String,
        executed: inout [String],
        warnings: inout [DuplicateWarning]
    ) async throws -> [[String?]] {
        do {
            let rows = try await driver.run(statement, sql: sql)
            executed.append(sql)
            return rows
        } catch {
            switch statement.severity {
            case .bestEffort:
                warnings.append(
                    .bestEffortStepFailed(
                        step: Self.stepDescription(statement.kind),
                        serverMessage: error.localizedDescription
                    )
                )
                return []
            case .fatal:
                throw DuplicateError.statementFailed(sql: sql, serverMessage: error.localizedDescription)
            }
        }
    }

    private func checkCancellation() throws {
        guard !token.isCancelled else { throw DuplicateError.cancelled }
    }

    // MARK: - Deferred statements

    struct HarvestedIndex: Sendable, Hashable {
        /// Already schema-qualified and quoted by `regclass`, so it is used verbatim. Quoting it
        /// again would turn `public.idx` into a single identifier named `public.idx`.
        let reference: String
        let definition: String
    }

    static func harvestedIndexes(from rows: [[String?]]) -> [HarvestedIndex] {
        rows.compactMap { row in
            guard row.count >= 2, let reference = row[0], let definition = row[1] else { return nil }
            guard !reference.isEmpty, !definition.isEmpty else { return nil }
            return HarvestedIndex(reference: reference, definition: definition)
        }
    }

    static func deferredSQL(for kind: DuplicateStatement.Kind, index: HarvestedIndex) -> String? {
        switch kind {
        case .dropIndex:
            return "DROP INDEX \(index.reference)"
        case .replayIndex:
            return index.definition
        default:
            return nil
        }
    }

    static func stepDescription(_ kind: DuplicateStatement.Kind) -> String {
        switch kind {
        case .analyze:
            return String(localized: "updating table statistics")
        case .tableComment:
            return String(localized: "copying the table comment")
        default:
            return String(localized: "one step")
        }
    }
}
