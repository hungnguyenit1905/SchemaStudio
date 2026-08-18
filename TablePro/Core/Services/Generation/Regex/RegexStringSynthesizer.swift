//
//  RegexStringSynthesizer.swift
//  TablePro
//

import Foundation

/// Walks a parsed pattern and draws one string that matches it. Every choice
/// comes from the column's own generator, so the same seed produces the same
/// value for ever.
enum RegexStringSynthesizer {
    static func synthesize(_ node: RegexPatternNode, using rng: inout SplitMix64) -> String {
        var value = ""
        append(node, to: &value, using: &rng)
        return value
    }

    private static func append(_ node: RegexPatternNode, to value: inout String, using rng: inout SplitMix64) {
        switch node {
        case .empty:
            return
        case .literal(let character):
            value.append(character)
        case .anyOf(let members):
            guard !members.isEmpty else { return }
            value.append(members[rng.nextInt(upperBound: members.count)])
        case .sequence(let nodes):
            for child in nodes {
                append(child, to: &value, using: &rng)
            }
        case .alternation(let branches):
            guard !branches.isEmpty else { return }
            append(branches[rng.nextInt(upperBound: branches.count)], to: &value, using: &rng)
        case .repeated(let child, let minimum, let maximum):
            let count = rng.nextInt(in: minimum...max(minimum, maximum))
            for _ in 0..<count {
                append(child, to: &value, using: &rng)
            }
        }
    }
}
