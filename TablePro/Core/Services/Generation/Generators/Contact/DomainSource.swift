//
//  DomainSource.swift
//  TablePro
//

import Foundation

/// Host names built from the locale's coined brand words. The default top-level
/// domains are the ones RFC 6761 reserves, so a generated host never resolves to
/// somebody's real server: a `website` column full of plausible `.com` names is a
/// liability the first time a test harness starts fetching them.
struct DomainSource {
    static let reservedTopLevels = ["test", "example", "invalid"]

    private let stems: [String]
    private let topLevels: [String]

    init(locale: GenerationLocale, topLevels requested: [String], generator: String) throws {
        let words = try LocaleWordSource(.companyWords, locale: locale, generator: generator).words
        let folded = Set(words.map { AsciiSlug.joined($0) }).filter { !$0.isEmpty }
        guard !folded.isEmpty else {
            throw GenerationError.invalidParameters(
                generator: generator,
                reason: "the company word list for \(locale.rawValue) holds nothing that can spell a host name"
            )
        }
        stems = folded.sorted()

        let cleaned = requested
            .map { AsciiSlug.words($0).joined(separator: ".") }
            .filter { !$0.isEmpty }
        topLevels = cleaned.isEmpty ? Self.reservedTopLevels : Array(Set(cleaned)).sorted()
    }

    func pick(using rng: inout SplitMix64) -> String {
        let stem = stems[rng.nextInt(upperBound: stems.count)]
        return "\(stem).\(topLevels[rng.nextInt(upperBound: topLevels.count)])"
    }

    var combinations: [String] {
        stems.flatMap { stem in topLevels.map { "\(stem).\($0)" } }
    }

    var distinctCount: Int { stems.count * topLevels.count }

    var longestLength: Int {
        (stems.map(\.count).max() ?? 0) + 1 + (topLevels.map(\.count).max() ?? 0)
    }
}
