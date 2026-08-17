//
//  BooleanGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

final class BooleanGenerator: ValueGenerator {
    static let identifier = "Boolean"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "truePercent",
            label: "True, percent of rows",
            type: .integer(minimum: 0, maximum: 100),
            defaultValue: .int(50)
        )
    ])

    private struct Params: Codable {
        var truePercent: Int?
    }

    private let truePercent: Int
    private let emitsInteger: Bool
    private let seed: UInt64
    private var rng: SplitMix64

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        let requested = decoded.truePercent ?? 50
        guard (0...100).contains(requested) else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "\(requested) is not a percentage"
            )
        }
        truePercent = requested
        emitsInteger = [.int8, .int16, .int32, .int64].contains(column.type.base)
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    var distinctValueCount: Int? { truePercent == 0 || truePercent == 100 ? 1 : 2 }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        let flag = rng.rollsBelow(percent: truePercent)
        guard emitsInteger else { return .bool(flag) }
        return .int(flag ? 1 : 0)
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
