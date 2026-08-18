//
//  LocaleWordSource.swift
//  TablePro
//

import Foundation

/// A dataset resolved once at build time and sampled per row. Holding the array
/// rather than re-reading the store on every draw is the whole point: the store
/// takes a lock, and the row loop must not.
struct LocaleWordSource: Sendable {
    let words: [String]

    var count: Int { words.count }

    init(_ dataset: GenerationDataset, locale: GenerationLocale, generator: String, store: LocaleDataStore = .shared) throws {
        let loaded = store.lines(dataset, locale: locale)
        guard !loaded.isEmpty else {
            throw GenerationError.invalidParameters(
                generator: generator,
                reason: "the \(dataset.rawValue) list for \(locale.rawValue) is missing from the app"
            )
        }
        words = loaded
    }

    func pick(using rng: inout SplitMix64) -> String {
        words[rng.nextInt(upperBound: words.count)]
    }
}
