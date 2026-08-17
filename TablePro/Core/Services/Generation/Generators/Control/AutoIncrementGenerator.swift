//
//  AutoIncrementGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

final class AutoIncrementGenerator: ValueGenerator {
    static let identifier = "AutoIncrement"
    static let excludesColumnFromInsert = true
    static let paramSchema = ParamSchema(fields: [
        ParamField(key: "start", label: "Start at", type: .integer(minimum: nil, maximum: nil), defaultValue: .int(1)),
        ParamField(key: "step", label: "Step by", type: .integer(minimum: nil, maximum: nil), defaultValue: .int(1))
    ])

    private struct Params: Codable {
        var start: Int64?
        var step: Int64?
    }

    private let start: Int64
    private let step: Int64
    private var emitted: Int64 = 0

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        let requestedStep = decoded.step ?? 1
        guard requestedStep != 0 else {
            throw GenerationError.invalidParameters(generator: Self.identifier, reason: "step cannot be zero")
        }
        start = decoded.start ?? 1
        step = requestedStep
    }

    var distinctValueCount: Int? { Int.max }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        defer { emitted += 1 }
        return .int(start &+ emitted &* step)
    }

    func reset() {
        emitted = 0
    }
}
