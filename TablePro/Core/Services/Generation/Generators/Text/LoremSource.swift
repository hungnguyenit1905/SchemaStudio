//
//  LoremSource.swift
//  TablePro
//

import Foundation

/// The lorem vocabulary and the three shapes built from it. Shared so the word,
/// sentence, paragraph and text generators cannot drift into four different
/// vocabularies, and so the sentence shape is defined once.
enum LoremSource {
    static let words = [
        "lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit",
        "sed", "do", "eiusmod", "tempor", "incididunt", "ut", "labore", "et", "dolore",
        "magna", "aliqua", "enim", "ad", "minim", "veniam", "quis", "nostrud",
        "exercitation", "ullamco", "laboris", "nisi", "aliquip", "ex", "ea", "commodo",
        "consequat", "duis", "aute", "irure", "in", "reprehenderit", "voluptate",
        "velit", "esse", "cillum", "eu", "fugiat", "nulla", "pariatur", "excepteur",
        "sint", "occaecat", "cupidatat", "non", "proident", "sunt", "culpa", "qui",
        "officia", "deserunt", "mollit", "anim", "id", "est", "laborum"
    ]

    static func phrase(wordCount: Int, using rng: inout SplitMix64) -> String {
        guard wordCount > 0 else { return "" }
        var picked: [String] = []
        picked.reserveCapacity(wordCount)
        for _ in 0..<wordCount {
            picked.append(words[rng.nextInt(upperBound: words.count)])
        }
        return picked.joined(separator: " ")
    }

    static func capitalized(_ value: String) -> String {
        guard let first = value.first else { return value }
        return String(first).uppercased() + value.dropFirst()
    }

    static func sentence(wordRange: ClosedRange<Int>, using rng: inout SplitMix64) -> String {
        let body = phrase(wordCount: rng.nextInt(in: wordRange), using: &rng)
        guard !body.isEmpty else { return "" }
        return capitalized(body) + "."
    }

    static func paragraph(
        sentenceRange: ClosedRange<Int>,
        wordRange: ClosedRange<Int>,
        using rng: inout SplitMix64
    ) -> String {
        let count = rng.nextInt(in: sentenceRange)
        guard count > 0 else { return "" }
        var sentences: [String] = []
        sentences.reserveCapacity(count)
        for _ in 0..<count {
            let built = sentence(wordRange: wordRange, using: &rng)
            guard !built.isEmpty else { continue }
            sentences.append(built)
        }
        return sentences.joined(separator: " ")
    }

    /// Clamps a user-supplied range so a maximum below the minimum, or a negative
    /// bound, cannot produce an empty `ClosedRange` and trap.
    static func range(minimum: Int?, maximum: Int?, defaults: ClosedRange<Int>, floor: Int) -> ClosedRange<Int> {
        let upper = max(floor, maximum ?? defaults.upperBound)
        let lower = max(floor, min(minimum ?? defaults.lowerBound, upper))
        return lower...upper
    }
}
