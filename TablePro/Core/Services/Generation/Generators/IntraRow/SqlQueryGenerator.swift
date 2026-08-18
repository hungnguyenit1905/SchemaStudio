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
        ),
        ParamField(
            key: "strategy",
            label: "Pick",
            type: .choice([
                ParamChoice(value: ReferenceStrategy.random.rawValue, label: String(localized: "At random")),
                ParamChoice(value: ReferenceStrategy.sequential.rawValue, label: String(localized: "In order"))
            ]),
            defaultValue: .string(ReferenceStrategy.random.rawValue)
        )
    ])

    private struct Params: Codable {
        var query: String?
        var column: String?
        var strategy: ReferenceStrategy?
    }

    private static let readOnlyKeywords = ["select", "with"]

    private let columnName: String
    private let strategy: ReferenceStrategy
    private let seed: UInt64
    private var rng: SplitMix64
    private var values: [PluginCellValue] = []
    private var position = 0

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
        strategy = decoded.strategy ?? .random
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    var distinctValueCount: Int? { values.isEmpty ? nil : Set(values).count }

    func bind(queryValues: [PluginCellValue]) {
        values = queryValues
        position = 0
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        guard !values.isEmpty else {
            throw GenerationError.dependencyMissing(column: columnName, dependsOn: querySource.query)
        }
        switch strategy {
        case .random:
            return values[rng.nextInt(upperBound: values.count)]
        case .sequential:
            defer { position += 1 }
            return values[position % values.count]
        }
    }

    func reset() {
        rng = SplitMix64(seed: seed)
        position = 0
    }

    /// Leading comments are stripped before the first keyword is read, because
    /// `/* note */ DELETE ...` would otherwise pass a naive prefix check.
    static func isReadOnly(_ query: String) -> Bool {
        var remainder = Substring(query.trimmingCharacters(in: .whitespacesAndNewlines))
        while true {
            if remainder.hasPrefix("--") {
                guard let newline = remainder.firstIndex(of: "\n") else { return false }
                remainder = remainder[remainder.index(after: newline)...]
            } else if remainder.hasPrefix("/*") {
                guard let close = remainder.range(of: "*/") else { return false }
                remainder = remainder[close.upperBound...]
            } else if let first = remainder.first, first.isWhitespace {
                remainder = remainder.dropFirst()
            } else {
                break
            }
        }
        let keyword = remainder.prefix { $0.isLetter }.lowercased()
        guard readOnlyKeywords.contains(keyword) else { return false }
        let body = remainder.hasSuffix(";") ? remainder.dropLast() : remainder
        return !body.contains(";")
    }
}
