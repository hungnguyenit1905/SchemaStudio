//
//  AffectedRowEstimator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal struct AffectedRowEstimator: Sendable {
    static let timeBox: Duration = .milliseconds(1_500)

    func estimate(connectionId: UUID, sql: String, databaseType: DatabaseType) async -> AffectedRowEstimate {
        guard QuerySqlParser.leadingWriteKind(from: sql) != nil else {
            return .undetermined(.notACountableStatement)
        }
        guard let statement = QuerySqlParser.parseSingleTableWrite(from: sql) else {
            return .undetermined(.couldNotDetermine)
        }

        let context = await MainActor.run { () -> (language: EditorLanguage, scope: DatabaseScope?) in
            (
                PluginManager.shared.editorLanguage(for: databaseType),
                DatabaseManager.shared.browseScope(for: connectionId)
            )
        }
        guard Self.supportsCounting(language: context.language) else {
            return .undetermined(.notACountableStatement)
        }
        guard let scope = context.scope else { return .undetermined(.couldNotDetermine) }

        let count = await Self.countRows(scope: scope, countSQL: Self.countStatement(for: statement))
        return Self.resolve(statement: statement, count: count)
    }

    static func supportsCounting(language: EditorLanguage) -> Bool {
        language == .sql
    }

    static func countStatement(for statement: SingleTableWriteStatement) -> String {
        guard let whereClause = statement.whereClause else {
            return "SELECT count(*) FROM \(statement.table)"
        }
        return "SELECT count(*) FROM \(statement.table) WHERE \(whereClause)"
    }

    static func resolve(statement: SingleTableWriteStatement, count: Int?) -> AffectedRowEstimate {
        guard statement.whereClause != nil else { return .wholeTable(count) }
        guard let count else { return .undetermined(.couldNotDetermine) }
        return .exact(count)
    }

    private enum RaceOutcome<Value: Sendable>: Sendable {
        case finished(Value?)
        case timedOut
    }

    static func firstResult<Value: Sendable>(
        within limit: Duration,
        of operation: @escaping @Sendable () async throws -> Value?
    ) async -> Value? {
        await withTaskGroup(of: RaceOutcome<Value>.self) { group in
            group.addTask {
                do {
                    return try await .finished(operation())
                } catch {
                    return .finished(nil)
                }
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return .timedOut
            }

            let outcome = await group.next() ?? .timedOut
            group.cancelAll()

            switch outcome {
            case .finished(let value):
                return value
            case .timedOut:
                return nil
            }
        }
    }

    private static func countRows(scope: DatabaseScope, countSQL: String) async -> Int? {
        await firstResult(within: timeBox) {
            try await DatabaseManager.shared.withMetadataDriver(
                scope: scope,
                workload: .interactive
            ) { driver in
                let result = try await driver.execute(query: countSQL)
                return result.rows.first?.first?.asText.flatMap { Int($0) }
            }
        }
    }
}
