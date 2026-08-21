//
//  LoremParagraphGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

final class LoremParagraphGenerator: ValueGenerator {
    static let identifier = "LoremParagraph"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "minSentences",
            label: "Fewest sentences",
            type: .integer(minimum: 1, maximum: nil),
            defaultValue: .int(3)
        ),
        ParamField(
            key: "maxSentences",
            label: "Most sentences",
            type: .integer(minimum: 1, maximum: nil),
            defaultValue: .int(6)
        ),
        ParamField(
            key: "minWords",
            label: "Fewest words",
            type: .integer(minimum: 1, maximum: nil),
            defaultValue: .int(6
        )),
        ParamField(
            key: "maxWords",
            label: "Most words",
            type: .integer(minimum: 1, maximum: nil),
            defaultValue: .int(16
        ))
    ])

    private struct Params: Codable {
        var minSentences: Int?
        var maxSentences: Int?
        var minWords: Int?
        var maxWords: Int?
    }

    private let sentenceRange: ClosedRange<Int>
    private let wordRange: ClosedRange<Int>
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
        sentenceRange = LoremSource.range(
            minimum: decoded.minSentences,
            maximum: decoded.maxSentences,
            defaults: 3...6,
            floor: 1
        )
        wordRange = LoremSource.range(minimum: decoded.minWords, maximum: decoded.maxWords, defaults: 6...16, floor: 1)
        maxLength = column.maxLength
        truncator = .forVendor(nil)
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        let paragraph = LoremSource.paragraph(sentenceRange: sentenceRange, wordRange: wordRange, using: &rng)
        return .text(truncator.truncate(paragraph, to: maxLength))
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
