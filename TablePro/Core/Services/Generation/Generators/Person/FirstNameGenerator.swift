//
//  FirstNameGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

final class FirstNameGenerator: ValueGenerator {
    static let identifier = "FirstName"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "locale",
            label: "Locale",
            type: .choice(GenerationLocale.paramChoices),
            defaultValue: .string(GenerationLocale.fallback.rawValue)
        ),
        ParamField(
            key: "gender",
            label: "Gender",
            type: .choice(PersonGender.paramChoices),
            defaultValue: .string(PersonGender.any.rawValue)
        )
    ])

    private struct Params: Codable {
        var locale: String?
        var gender: PersonGender?
    }

    private let names: GenderedNameSource
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
        let resolved = try GenderedNameSource(
            locale: GenerationLocale.resolve(decoded.locale),
            gender: decoded.gender ?? .any,
            generator: Self.identifier
        )
        names = resolved
        maxLength = column.maxLength
        let resolvedTruncator = GenerationStringTruncator.forVendor(nil)
        truncator = resolvedTruncator
        distinctCount = TruncatedCardinality.count(
            maxLength: column.maxLength,
            truncator: resolvedTruncator,
            product: resolved.distinctCount,
            combinations: { resolved.candidates }
        )
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    var distinctValueCount: Int? { distinctCount }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        .text(truncator.truncate(names.pick(using: &rng).name, to: maxLength))
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
