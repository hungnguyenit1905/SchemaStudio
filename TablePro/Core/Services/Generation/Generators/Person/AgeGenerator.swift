//
//  AgeGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

final class AgeGenerator: ValueGenerator {
    static let identifier = "Age"
    static let paramSchema = ParamSchema(fields: [
        ParamField(key: "min", label: "Youngest", type: .integer(minimum: 0, maximum: 150), defaultValue: .int(18)),
        ParamField(key: "max", label: "Oldest", type: .integer(minimum: 0, maximum: 150), defaultValue: .int(80))
    ])

    private struct Params: Codable {
        var min: Int?
        var max: Int?
    }

    private let range: ClosedRange<Int>
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
        let lower = min(150, max(0, decoded.min ?? 18))
        let upper = min(150, max(lower, decoded.max ?? 80))
        range = lower...upper
        base = column.type.base
        distinctCount = Self.resolveDistinctCount(range: range, base: base, maxLength: column.maxLength)
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    var distinctValueCount: Int? { distinctCount }

    /// A text column stores the number as the digits it renders to, so it
    /// truncates like any other string and the range stops describing the domain.
    /// Only a numeric column can trust the range itself.
    private static func resolveDistinctCount(
        range: ClosedRange<Int>,
        base: TransferBaseType,
        maxLength: Int?
    ) -> Int? {
        guard GenerationValueMapper.rendersIntegerAsText(base: base) else { return range.count }
        return TruncatedCardinality.count(
            maxLength: maxLength,
            truncator: .forVendor(nil),
            product: range.count,
            combinations: { range.map(String.init) }
        )
    }

    /// The shuffle over this domain writes the drawn number straight out, skipping
    /// both the value mapper and the length limit, so a column that stores the age
    /// as text has no domain to offer and falls back to tracking what it emitted.
    var integerDomain: ClosedRange<Int64>? {
        guard !GenerationValueMapper.rendersIntegerAsText(base: base) else { return nil }
        return Int64(range.lowerBound)...Int64(range.upperBound)
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        GenerationValueMapper.value(from: .int(rng.nextInt(in: range)), base: base)
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
