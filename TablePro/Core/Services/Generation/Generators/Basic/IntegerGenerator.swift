//
//  IntegerGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

final class IntegerGenerator: ValueGenerator {
    static let identifier = "Integer"
    static let paramSchema = ParamSchema(fields: [
        ParamField(key: "min", label: "Minimum", type: .integer(minimum: nil, maximum: nil), defaultValue: .null),
        ParamField(key: "max", label: "Maximum", type: .integer(minimum: nil, maximum: nil), defaultValue: .null),
        ParamField(key: "step", label: "Step", type: .integer(minimum: 1, maximum: nil), defaultValue: .int(1))
    ] + Distribution.paramFields)

    private struct Params: Codable {
        var min: Int64?
        var max: Int64?
        var step: Int64?
    }

    private let lowerBound: Int64
    private let stepCount: UInt64
    private let step: Int64
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
        let requestedStep = decoded.step ?? 1
        guard requestedStep > 0 else {
            throw GenerationError.invalidParameters(generator: Self.identifier, reason: "step must be positive")
        }
        let native = GenerationValueMapper.range(for: column.type.base, unsigned: column.type.unsigned)
        let lower = max(decoded.min ?? native.lowerBound, native.lowerBound)
        let upper = min(decoded.max ?? native.upperBound, native.upperBound)
        guard lower <= upper else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "the minimum \(lower) is above the maximum \(upper)"
            )
        }
        lowerBound = lower
        step = requestedStep
        let span = UInt64(bitPattern: upper &- lower)
        let reachableSteps = span / UInt64(requestedStep)
        stepCount = reachableSteps == UInt64.max ? UInt64.max : reachableSteps &+ 1
        distribution = try Distribution(params: params, generator: Self.identifier)
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    var distinctValueCount: Int? { GenerationValueMapper.saturatingCount(stepCount) }

    /// Only a step of one gives a contiguous domain, which is what the shuffle
    /// over `[min, max]` assumes.
    var integerDomain: ClosedRange<Int64>? {
        guard step == 1, stepCount > 0, stepCount <= ShuffledRangeSource.maximumDomain else { return nil }
        return lowerBound ... lowerBound &+ Int64(stepCount - 1)
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        guard !distribution.isUniform else {
            let offset = rng.next(span: stepCount)
            return .int(lowerBound &+ Int64(bitPattern: offset &* UInt64(step)))
        }
        let lastStep = Double(stepCount - 1)
        let lower = Double(lowerBound)
        let drawn = distribution.sample(in: lower...(lower + lastStep * Double(step)), using: &rng)
        let offset = Self.saturatingOffset(
            ((drawn - lower) / Double(step)).rounded(),
            upperBound: stepCount - 1
        )
        return .int(lowerBound &+ Int64(bitPattern: offset &* UInt64(step)))
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }

    /// A mean parked far outside the range exhausts `Distribution`'s redraw
    /// budget and clamps to the range's own upper bound, which for a `bigint`
    /// with no bounds is close enough to `Double`'s integer precision limit
    /// that rounding it up lands on `2^64`: not representable as `UInt64`, and
    /// the trapping initializer used to be handed exactly that value. Clamping
    /// in the integer domain instead of the floating one is what
    /// `GenerationValueMapper.saturatingCount` already does for the adjacent
    /// problem.
    private static func saturatingOffset(_ value: Double, upperBound: UInt64) -> UInt64 {
        guard value.isFinite, value > 0 else { return 0 }
        guard value < Double(UInt64.max) else { return upperBound }
        return min(UInt64(value), upperBound)
    }
}
