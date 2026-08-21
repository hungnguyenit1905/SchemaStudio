//
//  DoubleGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

final class DoubleGenerator: ValueGenerator {
    static let identifier = "Double"
    static let paramSchema = ParamSchema(fields: [
        ParamField(key: "min", label: "Minimum", type: .decimal(minimum: nil, maximum: nil), defaultValue: .int(0)),
        ParamField(key: "max", label: "Maximum", type: .decimal(minimum: nil, maximum: nil), defaultValue: .int(1))
    ] + Distribution.paramFields)

    private struct Params: Codable {
        var min: Double?
        var max: Double?
    }

    private let range: ClosedRange<Double>
    private let distribution: Distribution
    private let seed: UInt64
    private var rng: SplitMix64

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        let lower = decoded.min ?? 0
        let upper = decoded.max ?? 1
        guard lower <= upper, lower.isFinite, upper.isFinite, (upper - lower).isFinite else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "the range \(lower) to \(upper) is not usable"
            )
        }
        range = lower...upper
        distribution = try Distribution(params: params, generator: Self.identifier)
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        .double(distribution.sample(in: range, using: &rng))
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
