//
//  UsernameGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

final class UsernameGenerator: ValueGenerator {
    static let identifier = "Username"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "locale",
            label: "Locale",
            type: .choice(GenerationLocale.paramChoices),
            defaultValue: .string(GenerationLocale.fallback.rawValue)
        ),
        ParamField(
            key: "style",
            label: "Written as",
            type: .choice(HandleStyle.paramChoices),
            defaultValue: .string(HandleStyle.firstInitialLast.rawValue)
        )
    ])

    private struct Params: Codable {
        var locale: String?
        var style: HandleStyle?
    }

    private let handles: HandleSource
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
        let source = try HandleSource(
            locale: GenerationLocale.resolve(decoded.locale),
            style: decoded.style ?? .firstInitialLast,
            generator: Self.identifier
        )
        handles = source
        maxLength = column.maxLength
        let resolvedTruncator = GenerationStringTruncator.forVendor(nil)
        truncator = resolvedTruncator
        distinctCount = source.distinctCount.flatMap { product in
            TruncatedCardinality.count(
                maxLength: column.maxLength,
                truncator: resolvedTruncator,
                product: product,
                combinations: { source.combinations }
            )
        }
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    var distinctValueCount: Int? { distinctCount }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        .text(truncator.truncate(handles.pick(using: &rng), to: maxLength))
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
