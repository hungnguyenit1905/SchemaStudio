//
//  CopyGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

final class CopyGenerator: ValueGenerator {
    static let identifier = "Copy"
    static let paramSchema = ParamSchema(fields: [
        ParamField(key: "sourceColumn", label: "Copy from", type: .text, defaultValue: .string(""))
    ])

    private struct Params: Codable {
        var sourceColumn: String?
    }

    private let columnName: String
    private let sourceColumn: String

    var rowDependencies: [String] { [sourceColumn] }

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        let requested = decoded.sourceColumn ?? ""
        guard !requested.isEmpty else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "no source column was named"
            )
        }
        guard requested != column.name else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "a column cannot copy itself"
            )
        }
        columnName = column.name
        sourceColumn = requested
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        guard let value = row[sourceColumn] else {
            throw GenerationError.dependencyMissing(column: columnName, dependsOn: sourceColumn)
        }
        return value
    }

    func reset() {}
}
