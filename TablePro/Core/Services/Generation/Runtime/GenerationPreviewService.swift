//
//  GenerationPreviewService.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct GenerationPreviewTable: Sendable, Hashable {
    let table: String
    let columns: [String]
    let rows: [[PluginCellValue]]

    /// True when a parent this table draws from is part of the same run. The rows
    /// below are then drawn from the parent as it is *now*, while the run will draw
    /// from the rows it is about to write, so the values will differ even though
    /// their shape will not.
    let drawsFromGeneratedParent: Bool
}

struct GenerationPreview: Sendable, Hashable {
    let tables: [GenerationPreviewTable]
    let warnings: [GenerationWarning]

    static let empty = GenerationPreview(tables: [], warnings: [])
}

/// Builds the first rows a run would write, through the same `RowBuilder`,
/// `DecoratedGenerator` and `ReferencePoolBinder` the run uses.
///
/// Preview is not a second implementation of generation, because a preview that
/// disagrees with the run is worse than no preview at all. It is the row-building
/// half of the engine with nothing attached to write: it never empties a table,
/// never inserts, and never resets a sequence, so it is safe to run against the
/// user's database while they are still deciding.
///
/// Row values do not depend on how many rows are asked for. Every column draws
/// from a stream seeded by `FNV1a(masterSeed, table, column)`, and a reference
/// pool's draw order is fixed by its own seed, so the tenth previewed row is the
/// tenth row the run writes. The one exception is a table whose parent is also
/// being generated: there the run's pool is drawn from rows that do not exist yet,
/// and the preview says so through `drawsFromGeneratedParent`.
struct GenerationPreviewService {
    static let defaultRowCount = 20

    private let driver: any GenerationDriver
    private let registry: GeneratorRegistry
    private let truncator: GenerationStringTruncator
    private let options: GenerationRunOptions

    init(
        driver: any GenerationDriver,
        registry: GeneratorRegistry = .standard,
        truncator: GenerationStringTruncator = GenerationStringTruncator(unit: .unicodeScalars),
        options: GenerationRunOptions = GenerationRunOptions()
    ) {
        self.driver = driver
        self.registry = registry
        self.truncator = truncator
        self.options = options
    }

    func preview(
        plan: GenerationPlan,
        rowsPerTable: Int = GenerationPreviewService.defaultRowCount
    ) async throws -> GenerationPreview {
        var tables: [GenerationPreviewTable] = []
        var warnings: [GenerationWarning] = []
        let generated = Set(plan.tables.map(\.reference))

        for table in plan.tables {
            let rows = try await self.rows(for: table, plan: plan, limit: rowsPerTable, warnings: &warnings)
            tables.append(
                GenerationPreviewTable(
                    table: table.qualifiedName,
                    columns: table.insertColumns,
                    rows: rows,
                    drawsFromGeneratedParent: Self.drawsFromGeneratedParent(table, generated: generated)
                )
            )
        }
        return GenerationPreview(tables: tables, warnings: warnings)
    }

    func preview(
        table: TablePlan,
        plan: GenerationPlan,
        rowsPerTable: Int = GenerationPreviewService.defaultRowCount
    ) async throws -> GenerationPreviewTable {
        var warnings: [GenerationWarning] = []
        let rows = try await rows(for: table, plan: plan, limit: rowsPerTable, warnings: &warnings)
        return GenerationPreviewTable(
            table: table.qualifiedName,
            columns: table.insertColumns,
            rows: rows,
            drawsFromGeneratedParent: Self.drawsFromGeneratedParent(
                table,
                generated: Set(plan.tables.map(\.reference))
            )
        )
    }

    private func rows(
        for table: TablePlan,
        plan: GenerationPlan,
        limit: Int,
        warnings: inout [GenerationWarning]
    ) async throws -> [[PluginCellValue]] {
        let builder = try RowBuilder(
            plan: table,
            truncator: truncator,
            registry: registry,
            runSeed: plan.seed
        )
        var degraded: [String] = []
        let binder = ReferencePoolBinder(
            strategy: options.referenceStrategy,
            values: { key in
                try await driver.loadDistinctValues(key: key, limit: options.referencePoolLimit)
            },
            onDegrade: { degraded.append($0) }
        )
        try await binder.bind(to: builder, table: table, runSeed: plan.seed)

        var rows: [[PluginCellValue]] = []
        let wanted = max(0, min(limit, table.rowCount))
        rows.reserveCapacity(wanted)
        for index in 0 ..< wanted {
            rows.append(try builder.buildRow(index: index))
        }
        warnings.append(contentsOf: builder.warnings)
        warnings.append(
            contentsOf: degraded.map { GenerationWarning(column: table.qualifiedName, message: $0) }
        )
        return rows
    }

    private static func drawsFromGeneratedParent(
        _ table: TablePlan,
        generated: Set<GenerationTableReference>
    ) -> Bool {
        table.columns.contains { plan in
            guard let key = plan.column.foreignKey else { return false }
            let parent = GenerationTableReference(
                schema: key.referencedSchema ?? table.reference.schema,
                table: key.referencedTable
            )
            return parent != table.reference && generated.contains(parent)
        }
    }
}
