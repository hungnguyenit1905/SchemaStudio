//
//  ReferencePoolBinder.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Fills in every parent a table's builder draws from, single-column and
/// composite alike.
///
/// The engine and the preview both go through here, and that is the point: a
/// preview whose values differ from the run's is worse than no preview, and the
/// surest way to make them differ is to bind pools twice in two places. Where the
/// parent values are identical, the pools are identical, so the rows are too.
struct ReferencePoolBinder {
    typealias ValuesProvider = (ReferenceKey) async throws -> [[PluginCellValue]]

    private let values: ValuesProvider
    private let strategy: ReferencePoolStrategy
    private let onDegrade: (String) -> Void

    init(
        strategy: ReferencePoolStrategy,
        values: @escaping ValuesProvider,
        onDegrade: @escaping (String) -> Void
    ) {
        self.strategy = strategy
        self.values = values
        self.onDegrade = onDegrade
    }

    func bind(to builder: RowBuilder, table: TablePlan, runSeed: UInt64) async throws {
        for requirement in builder.referenceRequirements {
            let key = ReferenceKey(
                schema: requirement.target.schema,
                table: requirement.target.table,
                columns: [requirement.target.column]
            )
            let tuples = try await values(key)
            guard !tuples.isEmpty else {
                try degrade(requirement: requirement, table: table, key: key)
                builder.bind(pool: ReferenceValuePool(target: requirement.target, values: [.null]))
                continue
            }
            builder.bind(pool: ReferenceValuePool(target: requirement.target, values: tuples.map { $0[0] }))
        }

        for requirement in builder.compositeRequirements {
            let tuples = try await values(requirement.key)
            guard !tuples.isEmpty else {
                try degrade(requirement: requirement, table: table, key: requirement.key)
                builder.bind(
                    compositePool: try ReferencePool(
                        key: requirement.key,
                        tuples: [requirement.localColumns.map { _ in PluginCellValue.null }],
                        strategy: .random,
                        seed: Self.poolSeed(for: requirement.key, table: table, runSeed: runSeed)
                    )
                )
                continue
            }
            builder.bind(
                compositePool: try ReferencePool(
                    key: requirement.key,
                    tuples: tuples,
                    strategy: strategy,
                    seed: Self.poolSeed(for: requirement.key, table: table, runSeed: runSeed),
                    rowCount: table.rowCount
                )
            )
        }
    }

    /// An empty parent is only survivable where the column allows null. Anywhere
    /// else the run has to fail here rather than write rows the server rejects.
    private func degrade(
        requirement: some ReferenceRequiring,
        table: TablePlan,
        key: ReferenceKey
    ) throws {
        guard requirement.isNullable else {
            throw GenerationError.emptyParentTable(
                table: table.qualifiedName,
                column: requirement.localColumnList,
                parentTable: key.qualifiedName
            )
        }
        onDegrade(
            String(
                format: String(localized: "%@ is empty, so %@.%@ is left empty."),
                key.qualifiedName,
                table.qualifiedName,
                requirement.localColumnList
            )
        )
    }

    static func poolSeed(for key: ReferenceKey, table: TablePlan, runSeed: UInt64) -> UInt64 {
        GenerationSeed.columnSeed(
            runSeed: runSeed,
            table: table.qualifiedName,
            column: "\(key.qualifiedName).\(key.columns.joined(separator: ","))"
        )
    }
}
