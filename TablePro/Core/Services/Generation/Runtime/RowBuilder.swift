//
//  RowBuilder.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// A parent this table has to draw values from before its rows can be built.
protocol ReferenceRequiring {
    var isNullable: Bool { get }
    var localColumnList: String { get }
}

struct ReferenceRequirement: ReferenceRequiring, Sendable, Hashable {
    let target: ReferenceTarget
    let column: String
    let isNullable: Bool

    var localColumnList: String { column }
}

struct CompositeReferenceRequirement: ReferenceRequiring, Sendable, Hashable {
    let key: ReferenceKey
    let localColumns: [String]
    let isNullable: Bool

    var localColumnList: String { localColumns.joined(separator: ", ") }
}

/// Builds one row at a time for a single table. Owned by exactly one task for
/// the length of that table's row loop, which is what lets it stay a plain class:
/// an actor hop per row costs more than the row.
final class RowBuilder: @unchecked Sendable {
    private struct Column {
        let name: String
        let generator: DecoratedGenerator
        let consumer: (any ReferencePoolConsuming)?
        let isNullable: Bool
        let isDeferred: Bool
        let cardinality: Int?

        /// A deferred column is written as `NULL` on this pass and a column fed
        /// from a parent's tuple is not ours to change, so neither can be redrawn
        /// to settle a composite collision.
        let isRedrawable: Bool
    }

    private struct CompositeGroup {
        let key: ReferenceKey
        let localColumns: [String]
        let isNullable: Bool
        var pool: ReferencePool?
    }

    let table: GenerationTableReference
    let insertColumns: [String]

    private var columns: [Column] = []
    private var composites: [CompositeGroup] = []
    private var context: RowContext
    private var compositeUnique: CompositeUniqueTracker
    private let compositeRetryBudget: Int

    init(
        plan: TablePlan,
        truncator: GenerationStringTruncator,
        registry: GeneratorRegistry,
        runSeed: UInt64,
        compositeRetryBudget: Int = DecoratedGenerator.defaultUniqueRetryBudget
    ) throws {
        table = plan.reference
        insertColumns = plan.insertColumns
        context = RowContext(table: plan.qualifiedName, rowIndex: 0)
        self.compositeRetryBudget = compositeRetryBudget
        compositeUnique = CompositeUniqueTracker(constraints: [])

        let deferred = Set(plan.deferredColumns)
        let compositeColumns = Self.compositeGroups(in: plan)
        composites = compositeColumns
        let compositeMembers = Set(compositeColumns.flatMap(\.localColumns))

        for columnPlan in plan.columns {
            let columnSeed = GenerationSeed.columnSeed(
                runSeed: runSeed,
                table: plan.qualifiedName,
                column: columnPlan.name
            )
            let inner = try registry.make(
                identifier: columnPlan.generator,
                params: columnPlan.params,
                column: columnPlan.column,
                seed: columnSeed
            )
            columns.append(
                Column(
                    name: columnPlan.name,
                    generator: DecoratedGenerator(
                        inner: inner,
                        column: columnPlan.column,
                        common: columnPlan.common,
                        truncator: truncator,
                        seed: columnSeed,
                        rowCount: plan.rowCount
                    ),
                    consumer: compositeMembers.contains(columnPlan.name) ? nil : inner as? ReferencePoolConsuming,
                    isNullable: columnPlan.column.isNullable,
                    isDeferred: deferred.contains(columnPlan.name),
                    cardinality: inner.distinctValueCount,
                    isRedrawable: !deferred.contains(columnPlan.name)
                        && !compositeMembers.contains(columnPlan.name)
                        && !(inner is ReferencePoolConsuming)
                )
            )
        }

        let byName = Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0) })
        compositeUnique = CompositeUniqueTracker(
            constraints: CompositeUniqueTracker.constraints(
                for: plan,
                redrawable: { byName[$0]?.isRedrawable ?? false },
                cardinality: { byName[$0]?.cardinality }
            ),
            expectedCount: plan.rowCount
        )
    }

    var warnings: [GenerationWarning] {
        columns.flatMap(\.generator.warnings)
    }

    /// Single-column parents, one per generator that draws from an existing table.
    var referenceRequirements: [ReferenceRequirement] {
        columns.compactMap { column in
            guard let target = column.consumer?.referenceTarget else { return nil }
            return ReferenceRequirement(target: target, column: column.name, isNullable: column.isNullable)
        }
    }

    /// Composite parents, whose columns have to be drawn as one tuple.
    var compositeRequirements: [CompositeReferenceRequirement] {
        composites.map {
            CompositeReferenceRequirement(key: $0.key, localColumns: $0.localColumns, isNullable: $0.isNullable)
        }
    }

    func bind(pool: ReferenceValuePool) {
        for column in columns where column.consumer?.referenceTarget == pool.target {
            column.consumer?.bind(pool: pool)
        }
    }

    func bind(compositePool pool: ReferencePool) {
        for index in composites.indices where composites[index].key == pool.key {
            composites[index].pool = pool
        }
    }

    func buildRow(index: Int) throws -> [PluginCellValue] {
        context = RowContext(table: context.table, rowIndex: index)
        for group in composites {
            guard let tuple = group.pool?.next() else { continue }
            for (position, localColumn) in group.localColumns.enumerated() where position < tuple.count {
                context.set(tuple[position], for: localColumn)
            }
        }

        var values: [String: PluginCellValue] = [:]
        for column in columns {
            let value = try resolve(column, index: index)
            context.set(value, for: column.name)
            values[column.name] = value
        }
        try settleCompositeCollisions(in: &values, index: index)

        var row: [PluginCellValue] = []
        row.reserveCapacity(insertColumns.count)
        for name in insertColumns {
            row.append(values[name] ?? .null)
        }
        return row
    }

    private func settleCompositeCollisions(
        in values: inout [String: PluginCellValue],
        index: Int
    ) throws {
        guard !compositeUnique.isEmpty else { return }
        var attempts = 0
        while let collision = compositeUnique.collision(in: values) {
            guard attempts < compositeRetryBudget else {
                throw GenerationError.uniqueExhausted(
                    column: collision.columns.joined(separator: ", "),
                    attempts: attempts
                )
            }
            attempts += 1
            guard let column = columns.first(where: { $0.name == collision.redrawColumn }) else { return }
            let value = try column.generator.next(row: context, index: index)
            context.set(value, for: column.name)
            values[column.name] = value
        }
        compositeUnique.record(values)
    }

    func reset() {
        for column in columns {
            column.generator.reset()
        }
        for group in composites {
            group.pool?.reset()
        }
        compositeUnique.reset()
    }

    private func resolve(_ column: Column, index: Int) throws -> PluginCellValue {
        if column.isDeferred { return .null }
        if let preset = context[column.name] { return preset }
        return try column.generator.next(row: context, index: index)
    }

    private static func compositeGroups(in plan: TablePlan) -> [CompositeGroup] {
        var byConstraint: [String: GenerationForeignKey] = [:]
        for columnPlan in plan.columns {
            guard let key = columnPlan.column.foreignKey, key.isComposite else { continue }
            byConstraint[key.constraintName] = key
        }
        let planColumns = Set(plan.columns.map(\.name))
        return byConstraint.values
            .sorted { $0.constraintName < $1.constraintName }
            .filter { key in key.localColumns.allSatisfy(planColumns.contains) }
            .map { key in
                CompositeGroup(
                    key: ReferenceKey(
                        schema: key.referencedSchema ?? plan.reference.schema,
                        table: key.referencedTable,
                        columns: key.referencedColumns
                    ),
                    localColumns: key.localColumns,
                    isNullable: key.localColumns.allSatisfy { local in
                        plan.columns.first { $0.name == local }?.column.isNullable ?? false
                    },
                    pool: nil
                )
            }
    }
}
