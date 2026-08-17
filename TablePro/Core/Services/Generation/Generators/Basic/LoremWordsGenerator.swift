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

    private static let words = [
        "lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit",
        "sed", "do", "eiusmod", "tempor", "incididunt", "ut", "labore", "et", "dolore",
        "magna", "aliqua", "enim", "ad", "minim", "veniam", "quis", "nostrud",
        "exercitation", "ullamco", "laboris", "nisi", "aliquip", "ex", "ea", "commodo",
        "consequat", "duis", "aute", "irure", "in", "reprehenderit", "voluptate",
        "velit", "esse", "cillum", "eu", "fugiat", "nulla", "pariatur", "excepteur",
        "sint", "occaecat", "cupidatat", "non", "proident", "sunt", "culpa", "qui",
        "officia", "deserunt", "mollit", "anim", "id", "est", "laborum"
    ]

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
        let count = rng.nextInt(in: wordRange)
        var picked: [String] = []
        picked.reserveCapacity(count)
        for _ in 0..<count {
            picked.append(Self.words[rng.nextInt(upperBound: Self.words.count)])
        }
        var sentence = picked.joined(separator: " ")
        if capitalize, let first = sentence.first {
            sentence = String(first).uppercased() + sentence.dropFirst()
        }
        return .text(truncator.truncate(sentence, to: maxLength))
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
