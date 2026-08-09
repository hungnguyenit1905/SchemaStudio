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

        let context = await MainActor.run { () -> (isSQL: Bool, scope: DatabaseScope?) in
            (
                PluginManager.shared.editorLanguage(for: databaseType) == .sql,
                DatabaseManager.shared.browseScope(for: connectionId)
            )
        }
        guard context.isSQL else { return .undetermined(.notACountableStatement) }
        guard let scope = context.scope else { return .undetermined(.couldNotDetermine) }

        let count = await Self.countRows(scope: scope, countSQL: Self.countStatement(for: statement))
        return Self.resolve(statement: statement, count: count)
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

    private enum CountOutcome: Sendable {
        case finished(Int?)
        case timedOut
    }

    private static func countRows(scope: DatabaseScope, countSQL: String) async -> Int? {
        await withTaskGroup(of: CountOutcome.self) { group in
            group.addTask {
                do {
                    let value = try await DatabaseManager.shared.withMetadataDriver(
                        scope: scope,
                        workload: .interactive
                    ) { driver in
                        let result = try await driver.execute(query: countSQL)
                        return result.rows.first?.first?.asText.flatMap { Int($0) }
                    }
                    return .finished(value)
                } catch {
                    return .finished(nil)
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeBox)
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
}
