//
//  RegexStringSynthesizer.swift
//  TablePro
//

import Foundation

/// Walks a parsed pattern and draws one string that matches it. Every choice
/// comes from the column's own generator, so the same seed produces the same
/// value for ever.
enum RegexStringSynthesizer {
    /// Nested quantifiers multiply, not add: one repeat cap bounds a single
    /// `{n}`, but nothing bounded the product of several nested ones, so a
    /// pattern like `(((((\w{16}){16}){16}){16}){16})` synthesized gigabytes
    /// per row. This is the fallback for a column with no declared length at
    /// all, matching the cap this codebase already applies elsewhere to a
    /// single line of untrusted text.
    static let hardCeiling = 10_000

    static func synthesize(_ node: RegexPatternNode, budget: Int = hardCeiling, using rng: inout SplitMix64) -> String {
        var value = ""
        var remaining = max(0, budget)
        append(node, to: &value, remaining: &remaining, using: &rng)
        return value
    }

    /// The shortest string this pattern can ever produce, summing a sequence's
    /// children, taking the smallest branch of an alternation, and multiplying a
    /// repeat's own minimum by its child's. This is what lets a column refuse an
    /// explicit `{n}` before the first row, rather than synthesizing a value
    /// that can only ever be truncated into something that no longer matches.
    static func minimumLength(of node: RegexPatternNode) -> Int {
        switch node {
        case .empty:
            return 0
        case .literal:
            return 1
        case .anyOf(let members):
            return members.isEmpty ? 0 : 1
        case .sequence(let nodes):
            return nodes.reduce(0) { $0 + minimumLength(of: $1) }
        case .alternation(let branches):
            return branches.map(minimumLength(of:)).min() ?? 0
        case .repeated(let child, let minimum, _):
            return minimum * minimumLength(of: child)
        }
    }

    private static func append(
        _ node: RegexPatternNode,
        to value: inout String,
        remaining: inout Int,
        using rng: inout SplitMix64
    ) {
        guard remaining > 0 else { return }
        switch node {
        case .empty:
            return
        case .literal(let character):
            value.append(character)
            remaining -= 1
        case .anyOf(let members):
            guard !members.isEmpty else { return }
            value.append(members[rng.nextInt(upperBound: members.count)])
            remaining -= 1
        case .sequence(let nodes):
            for child in nodes {
                guard remaining > 0 else { break }
                append(child, to: &value, remaining: &remaining, using: &rng)
            }
        case .alternation(let branches):
            guard !branches.isEmpty else { return }
            append(branches[rng.nextInt(upperBound: branches.count)], to: &value, remaining: &remaining, using: &rng)
        case .repeated(let child, let minimum, let maximum):
            let count = rng.nextInt(in: minimum...max(minimum, maximum))
            for _ in 0..<count {
                guard remaining > 0 else { break }
                append(child, to: &value, remaining: &remaining, using: &rng)
            }
        }
    }
}
