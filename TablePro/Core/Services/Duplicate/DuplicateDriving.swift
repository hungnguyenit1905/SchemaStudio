//
//  DuplicateDriving.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The slice of a driver this feature needs, named after the two wire protocols rather than after
/// the driver methods, because which one a statement takes is a security decision and not an
/// implementation detail.
///
/// `runSimple` reaches PostgreSQL through `PQexec`, which accepts several statements in one
/// string. `runExtended` reaches it through `PQexecParams`, which refuses to. Anything carrying
/// text the user typed has to take the second path.
protocol DuplicateDriving: Sendable {
    var supportsTransactionalDDL: Bool { get }

    func quoteIdentifier(_ name: String) -> String
    func escapeStringLiteral(_ value: String) -> String

    func runSimple(_ sql: String) async throws -> [[String?]]
    func runExtended(_ sql: String) async throws -> [[String?]]

    func begin() async throws
    func commit() async throws
    func rollback() async throws
}

extension DuplicateDriving {
    /// The single place the protocol choice is made. Everything else asks for a statement to run
    /// and cannot pick the wrong path by accident.
    func run(_ statement: DuplicateStatement, sql: String) async throws -> [[String?]] {
        if statement.carriesRowFilter {
            return try await runExtended(sql)
        }
        return try await runSimple(sql)
    }

    var quoting: DuplicateSQLQuoting {
        DuplicateSQLQuoting(
            identifier: { self.quoteIdentifier($0) },
            stringLiteral: { self.escapeStringLiteral($0) }
        )
    }
}

/// Adapts the app's `DatabaseDriver` to the seam. `executeParameterized` with an empty parameter
/// list still uses the extended protocol: PostgreSQL's override does not short-circuit on an empty
/// list. A driver that leaves the PluginKit default in place would fall back to `execute` and lose
/// the guarantee, which is why `SQLBoundaryValidator` and not this is the primary defense.
struct DatabaseDriverDuplicateAdapter: DuplicateDriving {
    let driver: DatabaseDriver

    var supportsTransactionalDDL: Bool { driver.supportsTransactionalDDL }

    func quoteIdentifier(_ name: String) -> String { driver.quoteIdentifier(name) }

    func escapeStringLiteral(_ value: String) -> String { driver.escapeStringLiteral(value) }

    func runSimple(_ sql: String) async throws -> [[String?]] {
        Self.rows(from: try await driver.execute(query: sql))
    }

    func runExtended(_ sql: String) async throws -> [[String?]] {
        Self.rows(from: try await driver.executeParameterized(query: sql, parameters: []))
    }

    func begin() async throws { try await driver.beginTransaction(mode: .readWrite) }

    func commit() async throws { try await driver.commitTransaction() }

    func rollback() async throws { try await driver.rollbackTransaction() }

    private static func rows(from result: QueryResult) -> [[String?]] {
        result.rows.map { row in row.map(\.asText) }
    }
}
