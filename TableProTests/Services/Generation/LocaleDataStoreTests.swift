//
//  LocaleDataStoreTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import Testing

/// The datasets ship inside the app bundle, so a missing file is a packaging
/// fault that no caller can recover from: the generator that wanted it throws and
/// the whole run stops. These read every file the way the store does, which is
/// the only place that failure is caught before a user hits it.
@Suite("Locale data store")
struct LocaleDataStoreTests {
    private static let budgetBytes = 1_024 * 1_024

    private var bundle: Bundle { Bundle(for: LocaleDataStore.self) }

    private func url(_ dataset: GenerationDataset, _ locale: GenerationLocale) throws -> URL {
        try #require(
            bundle.url(forResource: "\(locale.rawValue)-\(dataset.rawValue)", withExtension: "txt"),
            "\(locale.rawValue)-\(dataset.rawValue).txt is missing from the app bundle"
        )
    }

    @Test("Every dataset ships for every locale", arguments: GenerationLocale.allCases)
    func everyDatasetShips(locale: GenerationLocale) throws {
        let store = LocaleDataStore()
        for dataset in GenerationDataset.allCases {
            _ = try url(dataset, locale)
            #expect(!store.lines(dataset, locale: locale).isEmpty, "\(dataset.rawValue) is empty for \(locale.rawValue)")
        }
    }

    @Test("Comments and blank lines never reach a generator", arguments: GenerationLocale.allCases)
    func commentsAreStripped(locale: GenerationLocale) {
        let store = LocaleDataStore()
        for dataset in GenerationDataset.allCases {
            let lines = store.lines(dataset, locale: locale)
            #expect(!lines.contains { $0.hasPrefix("#") })
            #expect(!lines.contains { $0.isEmpty })
            #expect(!lines.contains { $0 != $0.trimmingCharacters(in: .whitespaces) })
        }
    }

    /// The budget `DATASETS.md` records. Measured against the files themselves
    /// rather than the built bundle, because that is what a new dataset grows.
    @Test("The datasets stay inside the one megabyte budget")
    func datasetsFitTheBudget() throws {
        var total = 0
        for locale in GenerationLocale.allCases {
            for dataset in GenerationDataset.allCases {
                total += try Data(contentsOf: url(dataset, locale)).count
            }
        }
        #expect(total < Self.budgetBytes, "the datasets now measure \(total) bytes")
    }

    @Test("Localities parse into records rather than raw lines", arguments: GenerationLocale.allCases)
    func localitiesParse(locale: GenerationLocale) throws {
        let records = LocaleDataStore().localityRecords(locale: locale)
        #expect(records.count > 20)
        for record in records {
            #expect(!record.city.isEmpty)
            #expect(!record.state.isEmpty)
            #expect(!record.postalCode.isEmpty)
            #expect((-90...90).contains(record.latitude))
            #expect((-180...180).contains(record.longitude))
        }
    }

    @Test("A second read returns the same lines without touching the bundle again")
    func readsAreCached() {
        let store = LocaleDataStore()
        let first = store.lines(.lastNames, locale: .enUS)
        let second = store.lines(.lastNames, locale: .enUS)
        #expect(first == second)
        #expect(!first.isEmpty)
    }
}
