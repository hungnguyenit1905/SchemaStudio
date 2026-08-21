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
    typealias QueryValuesProvider = (SqlQuerySource) async throws -> [PluginCellValue]

    private let values: ValuesProvider
    private let queryValues: QueryValuesProvider
    private let strategy: ReferenceStrategy
    private let onDegrade: (String) -> Void

    init(
        strategy: ReferenceStrategy,
        values: @escaping ValuesProvider,
        queryValues: @escaping QueryValuesProvider,
        onDegrade: @escaping (String) -> Void
    ) {
        self.strategy = strategy
        self.values = values
        self.queryValues = queryValues
        self.onDegrade = onDegrade
    }

    func bind(to builder: RowBuilder, table: TablePlan, runSeed: UInt64) async throws {
        try await bindQueries(to: builder, table: table)

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
            try requirePoolFits(requirement: requirement, key: key, poolCount: tuples.count, table: table)
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

    /// A column that takes a parent row of its own runs out part way through the
    /// table when there are fewer parents than rows, so the pool is measured
    /// against the row count here, before anything is written.
    private func requirePoolFits(
        requirement: ReferenceRequirement,
        key: ReferenceKey,
        poolCount: Int,
        table: TablePlan
    ) throws {
        guard requirement.strategy == .oneToOne, table.rowCount > poolCount else { return }
        throw GenerationError.referencePoolTooSmall(
            table: key.qualifiedName,
            columns: key.columns,
            poolCount: poolCount,
            rowCount: table.rowCount
        )
    }

    /// Each distinct query runs once, however many columns draw from it, because
    /// a query is the expensive part of binding and two columns naming the same
    /// one mean the same values.
    private func bindQueries(to builder: RowBuilder, table: TablePlan) async throws {
        var loaded: [SqlQuerySource: [PluginCellValue]] = [:]
        for requirement in builder.queryRequirements {
            let source = requirement.source
            let available: [PluginCellValue]
            if let cached = loaded[source] {
                available = cached
            } else {
                available = try await queryValues(source).filter { !$0.isNull }
                loaded[source] = available
            }
            guard !available.isEmpty else {
                try degradeQuery(requirement: requirement, table: table)
                builder.bind(queryValues: [.null], for: source)
                continue
            }
            builder.bind(queryValues: available, for: source)
        }
    }

    /// A query that returns nothing is survivable only where the column allows
    /// null, exactly as an empty parent table is.
    private func degradeQuery(requirement: SqlQueryRequirement, table: TablePlan) throws {
        guard requirement.isNullable else {
            throw GenerationError.queryValuesUnavailable(
                table: table.qualifiedName,
                column: requirement.column
            )
        }
        onDegrade(
            String(
                format: String(localized: "The query for %@.%@ returned nothing, so the column is left empty."),
                table.qualifiedName,
                requirement.column
            )
        )
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
