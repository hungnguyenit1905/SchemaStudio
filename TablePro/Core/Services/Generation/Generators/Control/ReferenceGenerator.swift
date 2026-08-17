//
//  ReferenceGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum ReferenceStrategy: String, Codable, Sendable, CaseIterable {
    case random
    case sequential
    case roundRobin
}

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
    func bind(pool: ReferenceValuePool)
}

final class ReferenceGenerator: ValueGenerator, ReferencePoolConsuming {
    static let identifier = "Reference"
    static let paramSchema = ParamSchema(fields: [
        ParamField(key: "schema", label: "Schema", type: .text, defaultValue: .null),
        ParamField(key: "table", label: "Table", type: .text, defaultValue: .string("")),
        ParamField(key: "column", label: "Column", type: .text, defaultValue: .string("")),
        ParamField(
            key: "strategy",
            label: "Pick",
            type: .choice([
                ParamChoice(value: ReferenceStrategy.random.rawValue, label: String(localized: "At random")),
                ParamChoice(value: ReferenceStrategy.sequential.rawValue, label: String(localized: "In order")),
                ParamChoice(value: ReferenceStrategy.roundRobin.rawValue, label: String(localized: "Evenly"))
            ]),
            defaultValue: .string(ReferenceStrategy.random.rawValue)
        )
    ])

    private struct Params: Codable {
        var schema: String?
        var table: String?
        var column: String?
        var strategy: ReferenceStrategy?
    }

    private let columnName: String
    private let strategy: ReferenceStrategy
    private let seed: UInt64
    private var rng: SplitMix64
    private var pool: ReferenceValuePool?
    private var position = 0

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
        columnName = column.name
        referenceTarget = ReferenceTarget(
            schema: decoded.schema ?? column.foreignKey?.referencedSchema,
            table: table,
            column: referenced
        )
        strategy = decoded.strategy ?? .random
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    func bind(pool: ReferenceValuePool) {
        self.pool = pool
        position = 0
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        guard let pool, !pool.isEmpty else {
            throw GenerationError.dependencyMissing(
                column: columnName,
                dependsOn: "\(referenceTarget.table).\(referenceTarget.column)"
            )
        }
        switch strategy {
        case .random:
            return pool.values[rng.nextInt(upperBound: pool.values.count)]
        case .sequential, .roundRobin:
            defer { position += 1 }
            return pool.values[position % pool.values.count]
        }
    }

    func reset() {
        rng = SplitMix64(seed: seed)
        position = 0
    }
}
