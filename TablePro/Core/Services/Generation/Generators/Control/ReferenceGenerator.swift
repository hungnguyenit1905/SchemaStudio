//
//  ReferenceGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct ReferenceTarget: Sendable, Hashable {
    let schema: String?
    let table: String
    let column: String
}

struct ReferenceValuePool: Sendable, Hashable {
    let target: ReferenceTarget
    let values: [PluginCellValue]

    var isEmpty: Bool { values.isEmpty }
}

/// Implemented by any generator that draws from values already present in a
/// parent table. The engine collects the targets, loads each pool once, then
/// binds it before the run starts.
protocol ReferencePoolConsuming: AnyObject {
    var referenceTarget: ReferenceTarget { get }

    /// Read before the run so a strategy that pairs each row with its own parent
    /// is checked against the pool rather than running out part way through.
    var poolStrategy: ReferenceStrategy { get }

    func bind(pool: ReferenceValuePool)
}

final class ReferenceGenerator: ValueGenerator, ReferencePoolConsuming {
    static let identifier = "Reference"
    static let paramSchema = ParamSchema(fields: [
        ParamField(key: "schema", label: "Schema", type: .text, defaultValue: .null),
        ParamField(key: "table", label: "Table", type: .text, defaultValue: .string("")),
        ParamField(key: "column", label: "Column", type: .text, defaultValue: .string(""))
    ] + PoolValuePicker.paramFields())

    private struct Params: Codable {
        var schema: String?
        var table: String?
        var column: String?
        var strategy: ReferenceStrategy?
        var skew: Double?
    }

    private let columnName: String
    private let seed: UInt64
    private var picker: PoolValuePicker
    private var rng: SplitMix64
    private var pool: ReferenceValuePool?

    let poolStrategy: ReferenceStrategy

    let referenceTarget: ReferenceTarget

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        let requestedTable = decoded.table ?? ""
        let requestedColumn = decoded.column ?? ""
        let table = requestedTable.isEmpty ? (column.foreignKey?.referencedTable ?? "") : requestedTable
        let referenced = requestedColumn.isEmpty ? (column.referencedColumn ?? "") : requestedColumn
        guard !table.isEmpty, !referenced.isEmpty else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "no parent table and column to draw from"
            )
        }
        let inferred = requestedTable.isEmpty || requestedColumn.isEmpty
        if inferred, column.foreignKey?.isComposite == true {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "\(column.name) is part of a composite foreign key, whose columns have to be drawn together"
            )
        }
        columnName = column.name
        referenceTarget = ReferenceTarget(
            schema: decoded.schema ?? column.foreignKey?.referencedSchema,
            table: table,
            column: referenced
        )
        poolStrategy = decoded.strategy ?? .random
        picker = PoolValuePicker(
            strategy: poolStrategy,
            skew: decoded.skew ?? PoolValuePicker.defaultSkew,
            seed: seed
        )
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    func bind(pool: ReferenceValuePool) {
        self.pool = pool
        picker.bind(count: pool.values.count)
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        guard let pool, !pool.isEmpty else {
            throw GenerationError.dependencyMissing(
                column: columnName,
                dependsOn: "\(referenceTarget.table).\(referenceTarget.column)"
            )
        }
        guard let position = picker.nextIndex(count: pool.values.count, using: &rng) else {
            throw GenerationError.referencePoolTooSmall(
                table: referenceTarget.table,
                columns: [referenceTarget.column],
                poolCount: pool.values.count,
                rowCount: index + 1
            )
        }
        return pool.values[position]
    }

    func reset() {
        rng = SplitMix64(seed: seed)
        picker.bind(count: pool?.values.count ?? 0)
    }
}
