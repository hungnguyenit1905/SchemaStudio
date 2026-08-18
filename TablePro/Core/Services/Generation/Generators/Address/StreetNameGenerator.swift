//
//  StreetNameGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

final class StreetNameGenerator: ValueGenerator {
    static let identifier = "StreetName"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "locale",
            label: "Locale",
            type: .choice(GenerationLocale.paramChoices),
            defaultValue: .string(GenerationLocale.fallback.rawValue)
        )
    ])

    private struct Params: Codable {
        var locale: String?
    }

    private let streets: LocaleWordSource
    private let truncator: GenerationStringTruncator
    private let maxLength: Int?
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
        let resolved = try LocaleWordSource(
            .streetNames,
            locale: GenerationLocale.resolve(decoded.locale),
            generator: Self.identifier
        )
        streets = resolved
        maxLength = column.maxLength
        let resolvedTruncator = GenerationStringTruncator.forVendor(nil)
        truncator = resolvedTruncator
        distinctCount = TruncatedCardinality.count(
            maxLength: column.maxLength,
            truncator: resolvedTruncator,
            product: resolved.count,
            combinations: { resolved.words }
        )
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    var distinctValueCount: Int? { distinctCount }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        .text(truncator.truncate(streets.pick(using: &rng), to: maxLength))
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
