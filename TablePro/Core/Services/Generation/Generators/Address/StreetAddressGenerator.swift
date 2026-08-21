//
//  StreetAddressGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// House number plus street. English writes the number first, Vietnamese writes
/// the number then the street name in the same order, so the difference is the
/// street word itself rather than the arrangement.
final class StreetAddressGenerator: ValueGenerator {
    static let identifier = "StreetAddress"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "locale",
            label: "Locale",
            type: .choice(GenerationLocale.paramChoices),
            defaultValue: .string(GenerationLocale.fallback.rawValue)
        ),
        ParamField(
            key: "alleyPercent",
            label: "Alley numbers",
            type: .integer(minimum: 0, maximum: 100),
            defaultValue: .int(0)
        )
    ])

    private struct Params: Codable {
        var locale: String?
        var alleyPercent: Int?
    }

    private let streets: LocaleWordSource
    private let alleyPercent: Int
    private let truncator: GenerationStringTruncator
    private let maxLength: Int?
    private let seed: UInt64
    private var rng: SplitMix64

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        streets = try LocaleWordSource(
            .streetNames,
            locale: GenerationLocale.resolve(decoded.locale),
            generator: Self.identifier
        )
        alleyPercent = min(100, max(0, decoded.alleyPercent ?? 0))
        maxLength = column.maxLength
        truncator = .forVendor(nil)
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        let number = rng.nextInt(in: 1...500)
        let street = streets.pick(using: &rng)
        let house = rng.rollsBelow(percent: alleyPercent) ? "\(number)/\(rng.nextInt(in: 1...200))" : String(number)
        return .text(truncator.truncate("\(house) \(street)", to: maxLength))
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
