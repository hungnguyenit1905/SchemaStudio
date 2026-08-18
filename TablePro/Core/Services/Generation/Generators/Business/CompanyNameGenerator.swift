//
//  CompanyNameGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

final class CompanyNameGenerator: ValueGenerator {
    static let identifier = "CompanyName"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "locale",
            label: "Locale",
            type: .choice(GenerationLocale.paramChoices),
            defaultValue: .string(GenerationLocale.fallback.rawValue)
        ),
        ParamField(
            key: "includeSuffix",
            label: "Include legal suffix",
            type: .toggle,
            defaultValue: .bool(true),
            help: String(localized: "Adds the trading form, such as Inc. or Cong ty TNHH.")
        )
    ])

    private struct Params: Codable {
        var locale: String?
        var includeSuffix: Bool?
    }

    private let words: LocaleWordSource
    private let suffixes: LocaleWordSource?
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
        words = try LocaleWordSource(.companyWords, locale: locale, generator: Self.identifier)
        suffixes = (decoded.includeSuffix ?? true)
            ? try LocaleWordSource(.companySuffixes, locale: locale, generator: Self.identifier)
            : nil
        maxLength = column.maxLength
        let resolvedTruncator = GenerationStringTruncator.forVendor(nil)
        truncator = resolvedTruncator
        let resolvedWords = words
        let resolvedSuffixes = suffixes
        let resolvedLocale = locale
        distinctCount = TruncatedCardinality.count(
            maxLength: column.maxLength,
            truncator: resolvedTruncator,
            product: resolvedWords.count * (resolvedSuffixes?.count ?? 1),
            combinations: {
                guard let resolvedSuffixes else { return resolvedWords.words }
                return resolvedWords.words.flatMap { stem in
                    resolvedSuffixes.words.map { Self.compose(stem: stem, suffix: $0, locale: resolvedLocale) }
                }
            }
        )
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    var distinctValueCount: Int? { distinctCount }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        let stem = words.pick(using: &rng)
        guard let suffixes else { return .text(truncator.truncate(stem, to: maxLength)) }
        let suffix = suffixes.pick(using: &rng)
        return .text(truncator.truncate(Self.compose(stem: stem, suffix: suffix, locale: locale), to: maxLength))
    }

    /// Vietnamese trading forms lead the name, English ones follow it.
    private static func compose(stem: String, suffix: String, locale: GenerationLocale) -> String {
        locale == .viVN ? "\(suffix) \(stem)" : "\(stem) \(suffix)"
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
