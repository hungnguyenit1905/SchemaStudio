//
//  LoremWordsGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

final class LoremWordsGenerator: ValueGenerator {
    static let identifier = "LoremWords"
    static let paramSchema = ParamSchema(fields: [
        ParamField(key: "minWords", label: "Fewest words", type: .integer(minimum: 0, maximum: nil), defaultValue: .int(3)),
        ParamField(key: "maxWords", label: "Most words", type: .integer(minimum: 0, maximum: nil), defaultValue: .int(12)),
        ParamField(key: "capitalize", label: "Start with a capital", type: .toggle, defaultValue: .bool(true))
    ])

    private struct Params: Codable {
        var minWords: Int?
        var maxWords: Int?
        var capitalize: Bool?
    }

    private let wordRange: ClosedRange<Int>
    private let capitalize: Bool
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
        let upper = max(0, decoded.maxWords ?? 12)
        let lower = max(0, min(decoded.minWords ?? 3, upper))
        wordRange = lower...upper
        capitalize = decoded.capitalize ?? true
        maxLength = column.maxLength
        truncator = .forVendor(nil)
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        var phrase = LoremSource.phrase(wordCount: rng.nextInt(in: wordRange), using: &rng)
        if capitalize {
            phrase = LoremSource.capitalized(phrase)
        }
        return .text(truncator.truncate(phrase, to: maxLength))
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
