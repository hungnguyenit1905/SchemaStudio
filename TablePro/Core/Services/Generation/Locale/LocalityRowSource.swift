//
//  LocalityRowSource.swift
//  TablePro
//

import Foundation

/// Implemented by any generator that reads a field off a locality record. The
/// engine binds one source per table and locale before the run starts, which is
/// what makes `city`, `state` and `postal_code` in a single row describe the same
/// real place.
protocol LocalityConsuming: AnyObject {
    var localityLocale: GenerationLocale { get }
    func bind(localities: LocalityRowSource)
}

/// Hands out one record per row index, shared by every address column in a table.
///
/// The lookup is a pure function of the row index rather than a sequential draw,
/// because the columns inside a row are generated in dependency order and nothing
/// guarantees which address column asks first. A cursor would hand different
/// columns different records depending on that order; a hash cannot.
final class LocalityRowSource: @unchecked Sendable {
    let locale: GenerationLocale

    let records: [LocalityRecord]
    private let seed: UInt64
    private var cachedRow: Int?
    private var cachedRecord: LocalityRecord?

    var isEmpty: Bool { records.isEmpty }
    var count: Int { records.count }

    init(locale: GenerationLocale, records: [LocalityRecord], seed: UInt64) {
        self.locale = locale
        self.records = records
        self.seed = seed
    }

    convenience init(locale: GenerationLocale, seed: UInt64, store: LocaleDataStore = .shared) {
        self.init(locale: locale, records: store.localityRecords(locale: locale), seed: seed)
    }

    func record(forRow rowIndex: Int) -> LocalityRecord? {
        guard !records.isEmpty else { return nil }
        if cachedRow == rowIndex, let cachedRecord { return cachedRecord }
        var rng = SplitMix64(seed: seed &+ UInt64(bitPattern: Int64(rowIndex)) &* 0x9E37_79B9_7F4A_7C15)
        let record = records[rng.nextInt(upperBound: records.count)]
        cachedRow = rowIndex
        cachedRecord = record
        return record
    }
}
