//
//  SecondPassUpdater.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Fills the foreign keys that could not be filled while the rows were being
/// written: a self-reference (`employee.manager_id -> employee.id`), and the
/// nullable key a cycle was broken at.
///
/// Pass one wrote those columns as `NULL`. This pass reads the keys that now
/// exist, picks one per row from the column's own seeded stream, and updates the
/// rows it wrote. A table with no key to find its rows by cannot be updated at
/// all, and says so rather than leaving the caller to guess.
struct SecondPassUpdater {
    struct Outcome: Sendable {
        var rowsUpdated: Int
        var warnings: [GenerationWarning]
    }

    private let driver: any GenerationDriver
    private let poolLimit: Int

    init(driver: any GenerationDriver, poolLimit: Int) {
        self.driver = driver
        self.poolLimit = poolLimit
    }

    func fill(table: TablePlan, runSeed: UInt64) async throws -> Outcome {
        var outcome = Outcome(rowsUpdated: 0, warnings: [])
        guard !table.deferredColumns.isEmpty else { return outcome }
        guard !table.primaryKeyColumns.isEmpty else {
            outcome.warnings.append(
                GenerationWarning(
                    column: table.deferredColumns.joined(separator: ", "),
                    message: String(
                        format: String(
                            localized: "%@ has no primary key, so %@ stays empty: there is no way to find the rows again."
                        ),
                        table.qualifiedName,
                        table.deferredColumns.joined(separator: ", ")
                    )
                )
            )
            return outcome
        }

        let ownKeys = try await keys(of: table.reference, columns: table.primaryKeyColumns)
        guard !ownKeys.isEmpty else { return outcome }
        if ownKeys.count >= poolLimit {
            outcome.warnings.append(
                GenerationWarning(
                    column: table.deferredColumns.joined(separator: ", "),
                    message: String(
                        format: String(
                            localized: "%@ has more rows than the %d the second pass reads, so %@ stays empty past that point."
                        ),
                        table.qualifiedName,
                        poolLimit,
                        table.deferredColumns.joined(separator: ", ")
                    )
                )
            )
        }

        for columnName in table.deferredColumns {
            guard let plan = table.columns.first(where: { $0.name == columnName }) else { continue }
            guard let foreignKey = plan.column.foreignKey else { continue }
            guard let referenced = foreignKey.referencedColumn(forLocal: columnName) else { continue }
            let parent = GenerationTableReference(
                schema: foreignKey.referencedSchema ?? table.reference.schema,
                table: foreignKey.referencedTable
            )
            let parentKeys = try await keys(of: parent, columns: [referenced]).compactMap(\.first)
            guard !parentKeys.isEmpty else {
                outcome.warnings.append(
                    GenerationWarning(
                        column: columnName,
                        message: String(
                            format: String(localized: "%@ is empty, so %@.%@ stays empty."),
                            parent.qualifiedName,
                            table.qualifiedName,
                            columnName
                        )
                    )
                )
                continue
            }

            let isSelfReference = parent == table.reference
            let assignments = Self.assignments(
                ownKeys: ownKeys,
                parentKeys: parentKeys,
                keyColumnCount: table.primaryKeyColumns.count,
                avoidingOwnKey: isSelfReference,
                seed: GenerationSeed.columnSeed(
                    runSeed: runSeed,
                    table: table.qualifiedName,
                    column: "\(columnName).secondPass"
                )
            )
            guard !assignments.isEmpty else { continue }
            try await driver.update(
                table: table.reference,
                setColumns: [columnName],
                keyColumns: table.primaryKeyColumns,
                assignments: assignments
            )
            outcome.rowsUpdated += assignments.count
        }
        return outcome
    }

    /// A row never points at itself: `manager_id = id` reads as "is their own
    /// manager", which is not data anyone wants generated. Where the table has a
    /// single row there is nothing else to point at, so it stays null.
    static func assignments(
        ownKeys: [[PluginCellValue]],
        parentKeys: [PluginCellValue],
        keyColumnCount: Int,
        avoidingOwnKey: Bool,
        seed: UInt64
    ) -> [[PluginCellValue]] {
        var rng = SplitMix64(seed: seed)
        var rows: [[PluginCellValue]] = []
        rows.reserveCapacity(ownKeys.count)
        for ownKey in ownKeys {
            guard ownKey.count == keyColumnCount else { continue }
            guard let picked = pick(from: parentKeys, avoiding: avoidingOwnKey ? ownKey : nil, rng: &rng) else {
                continue
            }
            rows.append([picked] + ownKey)
        }
        return rows
    }

    private static func pick(
        from parentKeys: [PluginCellValue],
        avoiding ownKey: [PluginCellValue]?,
        rng: inout SplitMix64
    ) -> PluginCellValue? {
        guard !parentKeys.isEmpty else { return nil }
        let forbidden = ownKey?.count == 1 ? ownKey?.first?.stableHash : nil
        for _ in 0 ..< 8 {
            let candidate = parentKeys[rng.nextInt(upperBound: parentKeys.count)]
            guard let forbidden, candidate.stableHash == forbidden else { return candidate }
        }
        return parentKeys.first { forbidden == nil || $0.stableHash != forbidden }
    }

    private func keys(
        of table: GenerationTableReference,
        columns: [String]
    ) async throws -> [[PluginCellValue]] {
        try await driver.loadDistinctValues(
            key: ReferenceKey(schema: table.schema, table: table.table, columns: columns),
            limit: poolLimit
        )
    }
}
