//
//  LoremTextGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Several paragraphs, separated by a blank line. The article-length shape, for
/// a `text` column that a single paragraph would leave looking empty.
final class LoremTextGenerator: ValueGenerator {
    static let identifier = "LoremText"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "minParagraphs",
            label: "Fewest paragraphs",
            type: .integer(minimum: 1, maximum: nil),
            defaultValue: .int(2)
        ),
        ParamField(
            key: "maxParagraphs",
            label: "Most paragraphs",
            type: .integer(minimum: 1, maximum: nil),
            defaultValue: .int(4)
        ),
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
        )
    ])

    private struct Params: Codable {
        var minParagraphs: Int?
        var maxParagraphs: Int?
        var minSentences: Int?
        var maxSentences: Int?
    }

    private static let separator = "\n\n"

    private let paragraphRange: ClosedRange<Int>
    private let sentenceRange: ClosedRange<Int>
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
        paragraphRange = LoremSource.range(
            minimum: decoded.minParagraphs,
            maximum: decoded.maxParagraphs,
            defaults: 2...4,
            floor: 1
        )
        sentenceRange = LoremSource.range(
            minimum: decoded.minSentences,
            maximum: decoded.maxSentences,
            defaults: 3...6,
            floor: 1
        )
        maxLength = column.maxLength
        truncator = .forVendor(nil)
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        let count = rng.nextInt(in: paragraphRange)
        var paragraphs: [String] = []
        paragraphs.reserveCapacity(count)
        for _ in 0..<count {
            let built = LoremSource.paragraph(sentenceRange: sentenceRange, wordRange: 6...16, using: &rng)
            guard !built.isEmpty else { continue }
            paragraphs.append(built)
        }
        return .text(truncator.truncate(paragraphs.joined(separator: Self.separator), to: maxLength))
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
