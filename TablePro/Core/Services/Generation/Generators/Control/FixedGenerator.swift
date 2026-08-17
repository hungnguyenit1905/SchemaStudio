//
//  FixedGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

final class FixedGenerator: ValueGenerator {
    static let identifier = "Fixed"
    static let paramSchema = ParamSchema(fields: [
        ParamField(key: "value", label: "Value", type: .text, defaultValue: .string(""))
    ])

    private struct Params: Codable {
        var value: JSONValue?
    }

    private let value: PluginCellValue

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        value = GenerationValueMapper.value(from: decoded.value ?? .string(""), base: column.type.base)
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        value
    }

    func reset() {}
}
