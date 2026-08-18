//
//  FullAddressGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The whole postal address on one line, drawn from the same locality record the
/// row's other address columns use.
///
/// Ordering is the part that has to be right per locale: English runs
/// small to large and separates the state from the postal code with a space,
/// Vietnamese runs ward, province, then country with commas throughout.
final class FullAddressGenerator: ValueGenerator, LocalityConsuming {
    static let identifier = "FullAddress"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "locale",
            label: "Locale",
            type: .choice(GenerationLocale.paramChoices),
            defaultValue: .string(GenerationLocale.fallback.rawValue)
        ),
        ParamField(key: "includeCountry", label: "Include country", type: .toggle, defaultValue: .bool(false)),
        ParamField(
            key: "alleyPercent",
            label: "Alley numbers",
            type: .integer(minimum: 0, maximum: 100),
            defaultValue: .int(0)
        )
    ])

    private struct Params: Codable {
        var locale: String?
        var includeCountry: Bool?
        var alleyPercent: Int?
    }

    let localityLocale: GenerationLocale

    private let streets: LocaleWordSource
    private let includesCountry: Bool
    private let alleyPercent: Int
    private let truncator: GenerationStringTruncator
    private let maxLength: Int?
    private let fallback: LocalityRowSource
    private var bound: LocalityRowSource?
    private let seed: UInt64
    private var rng: SplitMix64

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        localityLocale = GenerationLocale.resolve(decoded.locale)
        streets = try LocaleWordSource(.streetNames, locale: localityLocale, generator: Self.identifier)
        fallback = LocalityRowSource(locale: localityLocale, seed: seed)
        guard !fallback.isEmpty else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "the locality list for \(localityLocale.rawValue) is missing from the app"
            )
        }
        includesCountry = decoded.includeCountry ?? false
        alleyPercent = min(100, max(0, decoded.alleyPercent ?? 0))
        maxLength = column.maxLength
        truncator = .forVendor(nil)
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    func bind(localities: LocalityRowSource) {
        bound = localities
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        let source = bound ?? fallback
        guard let record = source.record(forRow: row.rowIndex) else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "the locality list for \(localityLocale.rawValue) is empty"
            )
        }
        let number = rng.nextInt(in: 1...500)
        let house = rng.rollsBelow(percent: alleyPercent) ? "\(number)/\(rng.nextInt(in: 1...200))" : String(number)
        let street = "\(house) \(streets.pick(using: &rng))"
        return .text(truncator.truncate(compose(street: street, record: record), to: maxLength))
    }

    private func compose(street: String, record: LocalityRecord) -> String {
        var parts = [street, record.city]
        if localityLocale == .viVN {
            parts.append(record.state)
        } else {
            parts.append("\(record.stateCode) \(record.postalCode)")
        }
        if includesCountry {
            parts.append(CountryNames.name(forCode: record.countryCode, locale: localityLocale))
        }
        return parts.joined(separator: ", ")
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
