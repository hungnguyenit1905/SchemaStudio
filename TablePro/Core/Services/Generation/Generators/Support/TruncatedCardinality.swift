//
//  TruncatedCardinality.swift
//  TablePro
//

import Foundation

/// Resolves how many distinct values a word-combining generator can really
/// produce once the column's length limit is applied.
///
/// The cross product of the word lists is the wrong answer whenever the column
/// is short enough for two combinations to truncate to the same string, and an
/// overstated count is the dangerous direction: `GenerationProfileValidator`
/// uses it to decide whether a unique column can be filled, so overstating it
/// lets an unsatisfiable configuration through pre-flight and fails deep into
/// the run instead.
enum TruncatedCardinality {
    /// Above this many combinations the exact answer is not worth the work at
    /// build time, so the count falls back to "not computable" and the runtime
    /// uniqueness check takes over.
    static let inspectionLimit = 100_000

    static func count(
        maxLength: Int?,
        truncator: GenerationStringTruncator,
        product: Int,
        combinations: () -> [String]
    ) -> Int? {
        guard let maxLength else { return product }
        guard product > 0, product <= inspectionLimit else { return nil }
        let all = combinations()
        guard all.contains(where: { !truncator.fits($0, limit: maxLength) }) else { return product }
        return Set(all.map { truncator.truncate($0, to: maxLength) }).count
    }
}
