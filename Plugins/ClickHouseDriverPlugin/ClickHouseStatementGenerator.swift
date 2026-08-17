//
//  ClickHouseStatementGenerator.swift
//  ClickHouseDriverPlugin
//
//  Generates ClickHouse DML from tracked cell changes. ClickHouse expresses row
//  mutation as `ALTER TABLE ... UPDATE/DELETE WHERE` rather than plain UPDATE
//  and DELETE, so the app's generic SQL generator cannot produce it and the
//  driver supplies these statements itself.
//
//  Split out of the driver so the generation is testable without a connection,
//  matching BigQueryStatementGenerator and DynamoDBStatementGenerator.
//

import Foundation
import TableProPluginKit

internal struct ClickHouseStatementGenerator {
    typealias Statement = (statement: String, parameters: [PluginCellValue])

    let table: String
    let columns: [String]
    let primaryKeyColumns: [String]

    /// Whether the engine guarantees `primaryKeyColumns` identifies at most one
    /// row. Only then may a mutation narrow its WHERE to them; a non-unique key
    /// would let one edit rewrite every row that shares it.
    let keyIsUnique: Bool

    func generateStatements(
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [Statement]? {
        var statements: [Statement] = []

        for change in changes {
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex) else { continue }
                guard let values = insertedRowData[change.rowIndex] else { continue }
                if let statement = insert(values: values) {
                    statements.append(statement)
                }
            case .update:
                if let statement = update(change: change) {
                    statements.append(statement)
                }
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex) else { continue }
                if let statement = delete(change: change) {
                    statements.append(statement)
                }
            }
        }

        return statements.isEmpty ? nil : statements
    }

    // MARK: - Statements

    private func insert(values: [PluginCellValue]) -> Statement? {
        var insertColumns: [String] = []
        var parameters: [PluginCellValue] = []

        for (index, value) in values.enumerated() {
            if value.asText == "__DEFAULT__" { continue }
            guard index < columns.count else { continue }
            insertColumns.append(Self.quote(columns[index]))
            parameters.append(value)
        }

        guard !insertColumns.isEmpty else { return nil }

        let columnList = insertColumns.joined(separator: ", ")
        let placeholders = parameters.map { _ in "?" }.joined(separator: ", ")
        let sql = "INSERT INTO \(Self.quote(table)) (\(columnList)) VALUES (\(placeholders))"
        return (statement: sql, parameters: parameters)
    }

    private func update(change: PluginRowChange) -> Statement? {
        guard !change.cellChanges.isEmpty else { return nil }

        var parameters: [PluginCellValue] = []
        let setClauses = change.cellChanges.map { cellChange -> String in
            parameters.append(cellChange.newValue)
            return "\(Self.quote(cellChange.columnName)) = ?"
        }.joined(separator: ", ")

        guard let whereClause = self.whereClause(for: change, parameters: &parameters) else { return nil }

        let sql = "ALTER TABLE \(Self.quote(table)) UPDATE \(setClauses) WHERE \(whereClause)"
        return (statement: sql, parameters: parameters)
    }

    private func delete(change: PluginRowChange) -> Statement? {
        var parameters: [PluginCellValue] = []
        guard let whereClause = self.whereClause(for: change, parameters: &parameters) else { return nil }

        let sql = "ALTER TABLE \(Self.quote(table)) DELETE WHERE \(whereClause)"
        return (statement: sql, parameters: parameters)
    }

    // MARK: - WHERE

    /// Matches on the primary key alone when one is known.
    ///
    /// Every column in the WHERE has to compare equal for the mutation to hit
    /// the row, so a full-row match silently drops the mutation whenever any
    /// column round-trips to a value that no longer compares equal, and it
    /// makes ClickHouse scan far more than it needs to. Tables with no detected
    /// key still fall back to the full row, which is the only match available.
    private func whereClause(for change: PluginRowChange, parameters: inout [PluginCellValue]) -> String? {
        guard let originalRow = change.originalRow else { return nil }

        let matchColumns = self.matchColumns()
        var conditions: [String] = []

        for (index, columnName) in columns.enumerated() {
            guard matchColumns.contains(columnName) else { continue }
            guard index < originalRow.count else { continue }
            let quoted = Self.quote(columnName)
            let value = originalRow[index]
            if value.isNull {
                conditions.append("\(quoted) IS NULL")
            } else {
                parameters.append(value)
                conditions.append("\(quoted) = ?")
            }
        }

        guard !conditions.isEmpty else { return nil }
        return conditions.joined(separator: " AND ")
    }

    /// A primary key column the result set does not carry cannot be matched on,
    /// so a partial key falls back to the full row rather than narrowing the
    /// WHERE to the subset it happens to have. A key the engine does not
    /// guarantee unique falls back for the same reason.
    private func matchColumns() -> Set<String> {
        let available = Set(columns)
        guard keyIsUnique, !primaryKeyColumns.isEmpty else { return available }
        guard primaryKeyColumns.allSatisfy(available.contains) else { return available }
        return Set(primaryKeyColumns)
    }

    private static func quote(_ identifier: String) -> String {
        "`\(identifier.replacingOccurrences(of: "`", with: "``"))`"
    }
}
