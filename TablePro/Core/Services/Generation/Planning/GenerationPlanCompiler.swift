//
//  GenerationPlanCompiler.swift
//  TablePro
//

import Foundation

/// Turns a reconciled, validated profile into the ordered plan the engine runs.
struct GenerationPlanCompiler {
    private let registry: GeneratorRegistry
    private let canDisableConstraints: Bool

    init(registry: GeneratorRegistry = .standard, canDisableConstraints: Bool = false) {
        self.registry = registry
        self.canDisableConstraints = canDisableConstraints
    }

    func compile(profile: GenerationProfile, schema: [GenerationTable]) throws -> GenerationPlan {
        let selected = profile.tables.compactMap { tableProfile in
            schema.first { $0.name == tableProfile.table && $0.schema == tableProfile.schema }
        }
        let order = try DependencyResolver(canDisableConstraints: canDisableConstraints).resolve(selected)

        var plans: [TablePlan] = []
        for reference in order.ordered {
            guard
                let tableProfile = profile.table(named: reference.table, schema: reference.schema),
                let live = selected.first(where: { DependencyResolver.reference($0) == reference })
            else { continue }
            plans.append(
                try compile(
                    tableProfile: tableProfile,
                    live: live,
                    runSeed: profile.seed,
                    deferredColumns: order.deferredColumns[reference] ?? []
                )
            )
        }

        return GenerationPlan(
            seed: profile.seed,
            tables: plans,
            requiresConstraintDisable: order.requiresConstraintDisable
        )
    }

    private func compile(
        tableProfile: GenerationTableProfile,
        live: GenerationTable,
        runSeed: UInt64,
        deferredColumns: [String]
    ) throws -> TablePlan {
        let tableName = tableProfile.reference.qualifiedName
        var plansByName: [String: ColumnPlan] = [:]
        var dependencies: [String: [String]] = [:]

        for columnProfile in tableProfile.columns {
            guard let column = live.column(named: columnProfile.column) else {
                throw GenerationError.unknownColumn(table: tableName, column: columnProfile.column)
            }
            let generator = try registry.make(
                identifier: columnProfile.generator,
                params: columnProfile.paramData,
                column: column,
                seed: GenerationSeed.columnSeed(
                    runSeed: runSeed,
                    table: tableName,
                    column: column.name
                )
            )
            let excluded = column.isServerAssigned
                || registry.excludesColumnFromInsert(columnProfile.generator)
            plansByName[column.name] = ColumnPlan(
                column: column,
                generator: columnProfile.generator,
                params: columnProfile.paramData,
                common: columnProfile.common,
                excludedFromInsert: excluded,
                dependencies: generator.rowDependencies
            )
            dependencies[column.name] = generator.rowDependencies
        }

        let sorted = try ColumnDependencySorter.sort(
            columns: tableProfile.columns.map(\.column).filter { plansByName[$0] != nil },
            dependencies: dependencies,
            table: tableName
        )
        let columns = sorted.compactMap { plansByName[$0] }
        let deferred = Set(deferredColumns)

        return TablePlan(
            reference: tableProfile.reference,
            rowCount: tableProfile.rowCount,
            emptyFirst: tableProfile.emptyFirst,
            columns: columns,
            insertColumns: columns.filter { !$0.excludedFromInsert }.map(\.name),
            deferredColumns: columns.map(\.name).filter { deferred.contains($0) }
        )
    }
}
