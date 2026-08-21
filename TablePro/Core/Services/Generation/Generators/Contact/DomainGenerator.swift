//
//  DomainGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

final class DomainGenerator: ValueGenerator {
    static let identifier = "Domain"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "locale",
            label: "Locale",
            type: .choice(GenerationLocale.paramChoices),
            defaultValue: .string(GenerationLocale.fallback.rawValue)
        ),
        ParamField(
            key: "topLevels",
            label: "Top-level domains",
            type: .stringList,
            defaultValue: .array([]),
            help: String(localized: "Leave empty to use the reserved names that can never resolve.")
        )
    ])

    private struct Params: Codable {
        var locale: String?
        var topLevels: [String]?
    }

    private let domains: DomainSource
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
        let source = try DomainSource(
            locale: GenerationLocale.resolve(decoded.locale),
            topLevels: decoded.topLevels ?? [],
            generator: Self.identifier
        )
        domains = source
        maxLength = column.maxLength
        let resolvedTruncator = GenerationStringTruncator.forVendor(nil)
        truncator = resolvedTruncator
        distinctCount = TruncatedCardinality.count(
            maxLength: column.maxLength,
            truncator: resolvedTruncator,
            product: source.distinctCount,
            combinations: { source.combinations }
        )
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    var distinctValueCount: Int? { distinctCount }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        .text(truncator.truncate(domains.pick(using: &rng), to: maxLength))
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
