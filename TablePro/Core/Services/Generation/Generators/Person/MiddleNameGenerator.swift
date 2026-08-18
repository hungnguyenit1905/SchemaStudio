//
//  MiddleNameGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum MiddleNameForm: String, Codable, Sendable, CaseIterable {
    case full
    case initial
}

final class MiddleNameGenerator: ValueGenerator {
    static let identifier = "MiddleName"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "locale",
            label: "Locale",
            type: .choice(GenerationLocale.paramChoices),
            defaultValue: .string(GenerationLocale.fallback.rawValue)
        ),
        ParamField(
            key: "form",
            label: "Form",
            type: .choice([
                ParamChoice(value: MiddleNameForm.full.rawValue, label: String(localized: "Whole name")),
                ParamChoice(value: MiddleNameForm.initial.rawValue, label: String(localized: "Initial only"))
            ]),
            defaultValue: .string(MiddleNameForm.full.rawValue)
        )
    ])

    private struct Params: Codable {
        var locale: String?
        var form: MiddleNameForm?
    }

    private let names: LocaleWordSource
    private let form: MiddleNameForm
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
            .middleNames,
            locale: GenerationLocale.resolve(decoded.locale),
            generator: Self.identifier
        )
        names = resolved
        form = decoded.form ?? .full
        maxLength = column.maxLength
        let resolvedTruncator = GenerationStringTruncator.forVendor(nil)
        truncator = resolvedTruncator
        let resolvedForm = form
        distinctCount = TruncatedCardinality.count(
            maxLength: column.maxLength,
            truncator: resolvedTruncator,
            product: resolvedForm == .initial
                ? Set(resolved.words.compactMap { $0.first }).count
                : resolved.count,
            combinations: { resolved.words.map { Self.render($0, form: resolvedForm) } }
        )
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    var distinctValueCount: Int? { distinctCount }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        .text(truncator.truncate(Self.render(names.pick(using: &rng), form: form), to: maxLength))
    }

    private static func render(_ name: String, form: MiddleNameForm) -> String {
        guard form == .initial, let first = name.first else { return name }
        return "\(first)."
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
