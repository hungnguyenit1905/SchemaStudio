//
//  ProductNameGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

final class ProductNameGenerator: ValueGenerator {
    static let identifier = "ProductName"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "locale",
            label: "Locale",
            type: .choice(GenerationLocale.paramChoices),
            defaultValue: .string(GenerationLocale.fallback.rawValue)
        ),
        ParamField(
            key: "includeAdjective",
            label: "Include a describing word",
            type: .toggle,
            defaultValue: .bool(true)
        )
    ])

    private struct Params: Codable {
        var locale: String?
        var includeAdjective: Bool?
    }

    private let nouns: LocaleWordSource
    private let adjectives: LocaleWordSource?
    private let locale: GenerationLocale
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
        locale = GenerationLocale.resolve(decoded.locale)
        nouns = try LocaleWordSource(.productNouns, locale: locale, generator: Self.identifier)
        adjectives = (decoded.includeAdjective ?? true)
            ? try LocaleWordSource(.productAdjectives, locale: locale, generator: Self.identifier)
            : nil
        maxLength = column.maxLength
        let resolvedTruncator = GenerationStringTruncator.forVendor(nil)
        truncator = resolvedTruncator
        let resolvedNouns = nouns
        let resolvedAdjectives = adjectives
        let resolvedLocale = locale
        distinctCount = TruncatedCardinality.count(
            maxLength: column.maxLength,
            truncator: resolvedTruncator,
            product: resolvedNouns.count * (resolvedAdjectives?.count ?? 1),
            combinations: {
                guard let resolvedAdjectives else { return resolvedNouns.words }
                return resolvedNouns.words.flatMap { noun in
                    resolvedAdjectives.words.map { Self.compose(noun: noun, adjective: $0, locale: resolvedLocale) }
                }
            }
        )
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    var distinctValueCount: Int? { distinctCount }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        let noun = nouns.pick(using: &rng)
        guard let adjectives else { return .text(truncator.truncate(noun, to: maxLength)) }
        let adjective = adjectives.pick(using: &rng)
        return .text(
            truncator.truncate(Self.compose(noun: noun, adjective: adjective, locale: locale), to: maxLength)
        )
    }

    /// Vietnamese puts the describing word after the noun.
    private static func compose(noun: String, adjective: String, locale: GenerationLocale) -> String {
        locale == .viVN ? "\(noun) \(adjective)" : "\(adjective) \(noun)"
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
