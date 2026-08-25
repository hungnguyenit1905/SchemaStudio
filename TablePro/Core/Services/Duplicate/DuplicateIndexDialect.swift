//
//  DuplicateIndexDialect.swift
//  TablePro
//

import Foundation

/// One index the server reported on the freshly created target.
struct DuplicateHarvestedIndex: Sendable, Hashable {
    /// PostgreSQL: the schema-qualified name `regclass` already quoted, used verbatim. MySQL: the
    /// bare index name, which is quoted when the drop clause is written.
    let reference: String
    /// PostgreSQL: the whole `CREATE INDEX` statement. MySQL: the index line out of
    /// `SHOW CREATE TABLE`, which is the body of an `ADD` clause.
    let definition: String
}

/// How one vendor reports the indexes on a table and how those indexes are dropped and put back.
///
/// The two vendors differ in all three answers, and the difference is not cosmetic. PostgreSQL
/// hands back one row per index and takes one statement per index. MySQL hands back the entire
/// create statement in a single row and rebuilds the table once per `ALTER`, so every index has
/// to travel in one `ALTER` or a table with six indexes is rebuilt six times.
enum DuplicateIndexDialect: Sendable, Hashable {
    case postgresql
    /// Carries the already quoted, qualified target name, because every MySQL index statement is
    /// an `ALTER TABLE` on it.
    case mysql(target: String)

    func harvestedIndexes(from rows: [[String?]]) -> [DuplicateHarvestedIndex] {
        switch self {
        case .postgresql:
            return rows.compactMap { row in
                guard row.count >= 2, let reference = row[0], let definition = row[1] else { return nil }
                guard !reference.isEmpty, !definition.isEmpty else { return nil }
                return DuplicateHarvestedIndex(reference: reference, definition: definition)
            }
        case .mysql:
            // `SHOW CREATE TABLE` answers with one row: the table name, then the statement.
            guard let statement = rows.first?.last ?? nil, !statement.isEmpty else { return [] }
            return MySQLCreateTableIndexHarvest.indexes(inCreateTable: statement).map {
                DuplicateHarvestedIndex(reference: $0.name, definition: $0.definition)
            }
        }
    }

    func dropSQL(for indexes: [DuplicateHarvestedIndex], quoting: DuplicateSQLQuoting) -> [String] {
        guard !indexes.isEmpty else { return [] }
        switch self {
        case .postgresql:
            return indexes.map { "DROP INDEX \($0.reference)" }
        case .mysql(let target):
            let clauses = indexes.map { "DROP INDEX \(quoting.identifier($0.reference))" }
            return ["ALTER TABLE \(target) \(clauses.joined(separator: ", "))"]
        }
    }

    /// The replay needs no quoting: PostgreSQL replays the statement the server printed and MySQL
    /// replays the line the server printed, both already quoted by whoever wrote them.
    func replaySQL(for indexes: [DuplicateHarvestedIndex]) -> [String] {
        guard !indexes.isEmpty else { return [] }
        switch self {
        case .postgresql:
            return indexes.map(\.definition)
        case .mysql(let target):
            let clauses = indexes.map { "ADD \($0.definition)" }
            return ["ALTER TABLE \(target) \(clauses.joined(separator: ", "))"]
        }
    }
}
