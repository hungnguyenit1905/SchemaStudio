//
//  SqlQueryGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct SqlQuerySource: Sendable, Hashable {
    let query: String
    let column: String?
}

/// Implemented by any generator whose values come from a query the user wrote.
/// The engine runs each query once before the rows start, exactly as it loads a
/// reference pool, so nothing here touches the server inside the row loop.
protocol SqlQueryConsuming: AnyObject {
    var querySource: SqlQuerySource { get }
    func bind(queryValues: [PluginCellValue])
}

/// Draws from a read-only query against the connection being generated into.
///
/// The statement is checked to be a `SELECT` (or a `WITH` that leads to one)
/// before it is ever sent: this runs against the user's own database with their
/// own credentials, and a generator is not a place to discover that a typed
/// statement was a `DELETE`. Generated values are never interpolated into it.
final class SqlQueryGenerator: ValueGenerator, SqlQueryConsuming {
    static let identifier = "SQLQuery"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "query",
            label: "Query",
            type: .multilineText,
            defaultValue: .string(""),
            help: String(localized: "A SELECT that returns the values to draw from.")
        ),
        ParamField(
            key: "column",
            label: "Column",
            type: .text,
            defaultValue: .string(""),
            help: String(localized: "Leave empty to use the first column of the result.")
        )
    ] + PoolValuePicker.paramFields(strategies: ReferenceStrategy.freeDrawCases))

    private struct Params: Codable {
        var query: String?
        var column: String?
        var strategy: ReferenceStrategy?
        var skew: Double?
    }

    private let columnName: String
    private let seed: UInt64
    private var picker: PoolValuePicker
    private var rng: SplitMix64
    private var values: [PluginCellValue] = []

    let querySource: SqlQuerySource

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        let query = (decoded.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw GenerationError.invalidParameters(generator: Self.identifier, reason: "no query was written")
        }
        guard Self.isReadOnly(query) else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "only a SELECT can supply generated values"
            )
        }
        columnName = column.name
        let requestedColumn = decoded.column ?? ""
        querySource = SqlQuerySource(query: query, column: requestedColumn.isEmpty ? nil : requestedColumn)
        let strategy = decoded.strategy ?? .random
        guard strategy.drawsFreely else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "\(strategy.rawValue) pairs rows with a parent table, so a query cannot use it"
            )
        }
        picker = PoolValuePicker(strategy: strategy, skew: decoded.skew ?? PoolValuePicker.defaultSkew, seed: seed)
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    var distinctValueCount: Int? { values.isEmpty ? nil : Set(values).count }

    func bind(queryValues: [PluginCellValue]) {
        values = queryValues
        picker.bind(count: queryValues.count)
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        guard !values.isEmpty else {
            throw GenerationError.dependencyMissing(column: columnName, dependsOn: querySource.query)
        }
        guard let position = picker.nextIndex(count: values.count, using: &rng) else {
            throw GenerationError.queryValuesUnavailable(table: querySource.query, column: columnName)
        }
        return values[position]
    }

    func reset() {
        rng = SplitMix64(seed: seed)
        picker.bind(count: values.count)
    }

    static func isReadOnly(_ query: String) -> Bool {
        ReadOnlyQueryGate.isReadOnly(query)
    }
}
