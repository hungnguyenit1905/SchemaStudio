//
//  SimpleWordListGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// One dataset, one column, nothing else. `LastName`, `JobTitle` and `Title` are
/// the same code over different files, so the file is the only thing each one
/// declares.
protocol WordListField {
    static var identifier: String { get }
    static var dataset: GenerationDataset { get }
}

enum LastNameField: WordListField {
    static let identifier = "LastName"
    static let dataset = GenerationDataset.lastNames
}

enum JobTitleField: WordListField {
    static let identifier = "JobTitle"
    static let dataset = GenerationDataset.jobTitles
}

enum PersonTitleField: WordListField {
    static let identifier = "Title"
    static let dataset = GenerationDataset.titles
}

final class SimpleWordListGenerator<Field: WordListField>: ValueGenerator {
    static var identifier: String { Field.identifier }

    static var paramSchema: ParamSchema {
        ParamSchema(fields: [
            ParamField(
                key: "locale",
                label: "Locale",
                type: .choice(GenerationLocale.paramChoices),
                defaultValue: .string(GenerationLocale.fallback.rawValue)
            )
        ])
    }

    private struct Params: Codable {
        var locale: String?
    }

    private let words: LocaleWordSource
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
            Field.dataset,
            locale: GenerationLocale.resolve(decoded.locale),
            generator: Self.identifier
        )
        words = resolved
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
        .text(truncator.truncate(words.pick(using: &rng), to: maxLength))
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
