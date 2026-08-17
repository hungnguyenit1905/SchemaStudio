//
//  DecimalGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Values are produced as a scaled `Int64` and formatted once. `Foundation.Decimal`
/// arithmetic is software arithmetic over a 20-byte struct, which is far too slow
/// for a million rows, and `Double` cannot hold a PostgreSQL `numeric` losslessly.
final class DecimalGenerator: ValueGenerator {
    static let identifier = "Decimal"
    static let paramSchema = ParamSchema(fields: [
        ParamField(key: "min", label: "Minimum", type: .decimal(minimum: nil, maximum: nil), defaultValue: .int(0)),
        ParamField(
            key: "max",
            label: "Maximum",
            type: .decimal(minimum: nil, maximum: nil),
            defaultValue: .int(10_000)
        ),
        ParamField(key: "scale", label: "Decimal places", type: .integer(minimum: 0, maximum: 18), defaultValue: .null)
    ])

    private struct Params: Codable {
        var min: Double?
        var max: Double?
        var scale: Int?
    }

    private let scale: Int
    private let unscaledLowerBound: Int64
    private let unscaledSpan: UInt64
    private let seed: UInt64
    private var rng: SplitMix64

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        let lowerRequest = decoded.min ?? 0
        let upperRequest = decoded.max ?? 10_000
        let resolvedScale = max(0, min(decoded.scale ?? column.type.scale ?? 2, 18))
        guard lowerRequest <= upperRequest else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "the minimum \(lowerRequest) is above the maximum \(upperRequest)"
            )
        }
        let factor = Self.powerOfTen(resolvedScale)
        var lower = (lowerRequest * Double(factor)).rounded(.up)
        var upper = (upperRequest * Double(factor)).rounded(.down)
        if let precision = column.type.precision {
            let ceiling = Double(Self.powerOfTen(max(0, precision)) - 1)
            lower = max(lower, -ceiling)
            upper = min(upper, ceiling)
        }
        lower = Swift.max(lower, Double(Int64.min / 2))
        upper = Swift.min(upper, Double(Int64.max / 2))
        guard lower <= upper else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "no value fits the column's precision and scale"
            )
        }
        scale = resolvedScale
        unscaledLowerBound = Int64(lower)
        unscaledSpan = UInt64(upper - lower) &+ 1
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    var distinctValueCount: Int? { GenerationValueMapper.saturatingCount(unscaledSpan) }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        let unscaled = unscaledLowerBound &+ Int64(bitPattern: rng.next(span: unscaledSpan))
        return .decimalText(Self.format(unscaled: unscaled, scale: scale))
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }

    static func format(unscaled: Int64, scale: Int) -> String {
        guard scale > 0 else { return String(unscaled) }
        let negative = unscaled < 0
        let digits = String(unscaled.magnitude)
        let padded = digits.count > scale
            ? digits
            : String(repeating: "0", count: scale - digits.count + 1) + digits
        let splitPoint = padded.index(padded.endIndex, offsetBy: -scale)
        let whole = padded[padded.startIndex..<splitPoint]
        let fraction = padded[splitPoint...]
        return (negative ? "-" : "") + whole + "." + fraction
    }

    private static func powerOfTen(_ exponent: Int) -> Int64 {
        var result: Int64 = 1
        for _ in 0..<min(exponent, 18) { result &*= 10 }
        return result
    }
}
