//
//  BuildingNumberGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// House numbers, occasionally with a Vietnamese-style alley suffix such as
/// `12/34`, which is what makes a generated address read as a real one there.
final class BuildingNumberGenerator: ValueGenerator {
    static let identifier = "BuildingNumber"
    static let paramSchema = ParamSchema(fields: [
        ParamField(key: "min", label: "Lowest", type: .integer(minimum: 1, maximum: nil), defaultValue: .int(1)),
        ParamField(key: "max", label: "Highest", type: .integer(minimum: 1, maximum: nil), defaultValue: .int(500)),
        ParamField(
            key: "alleyPercent",
            label: "Alley numbers",
            type: .integer(minimum: 0, maximum: 100),
            defaultValue: .int(0),
            help: String(localized: "How often to write a nested number such as 12/34.")
        )
    ])

    private struct Params: Codable {
        var min: Int?
        var max: Int?
        var alleyPercent: Int?
    }

    private let range: ClosedRange<Int>
    private let alleyPercent: Int
    private let base: TransferBaseType
    private let distinctCount: Int?
    private let seed: UInt64
    private var rng: SplitMix64

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        let lower = max(1, decoded.min ?? 1)
        let upper = max(lower, decoded.max ?? 500)
        range = lower...upper
        alleyPercent = min(100, max(0, decoded.alleyPercent ?? 0))
        base = column.type.base
        distinctCount = Self.resolveDistinctCount(
            range: range,
            alleyPercent: alleyPercent,
            base: column.type.base,
            maxLength: column.maxLength
        )
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    var distinctValueCount: Int? { distinctCount }

    /// An alley number combines two draws, so its domain is not this range at
    /// all. A text column truncates the number it is given, which collapses the
    /// range further, so only a numeric column can trust the range itself.
    private static func resolveDistinctCount(
        range: ClosedRange<Int>,
        alleyPercent: Int,
        base: TransferBaseType,
        maxLength: Int?
    ) -> Int? {
        guard alleyPercent == 0 else { return nil }
        guard GenerationValueMapper.rendersIntegerAsText(base: base) else { return range.count }
        return TruncatedCardinality.count(
            maxLength: maxLength,
            truncator: .forVendor(nil),
            product: range.count,
            combinations: { range.map(String.init) }
        )
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        let number = rng.nextInt(in: range)
        guard rng.rollsBelow(percent: alleyPercent) else {
            return GenerationValueMapper.value(from: .int(number), base: base)
        }
        return .text("\(number)/\(rng.nextInt(in: range))")
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
