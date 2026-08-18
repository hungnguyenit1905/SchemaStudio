//
//  ReferencePool.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The parent columns a pool is drawn from. A composite foreign key names more
/// than one, and the tuple is what the pool stores: sampling each column on its
/// own produces combinations the parent never had.
struct ReferenceKey: Sendable, Hashable {
    let schema: String?
    let table: String
    let columns: [String]

    var qualifiedName: String {
        guard let schema, !schema.isEmpty else { return table }
        return "\(schema).\(table)"
    }
}

/// Owned by exactly one task for the length of a table's row loop. It is
/// deliberately not an actor: an actor hop per row costs more than every value
/// it hands out.
final class ReferencePool: @unchecked Sendable {
    let key: ReferenceKey
    let strategy: ReferenceStrategy

    private let tuples: [[PluginCellValue]]
    private let seed: UInt64
    private var rng: SplitMix64
    private var picker: PoolValuePicker

    var count: Int { tuples.count }
    var isEmpty: Bool { tuples.isEmpty }

    init(
        key: ReferenceKey,
        tuples: [[PluginCellValue]],
        strategy: ReferenceStrategy = .random,
        skew: Double = PoolValuePicker.defaultSkew,
        seed: UInt64,
        rowCount: Int? = nil
    ) throws {
        if strategy == .oneToOne, let rowCount, rowCount > tuples.count {
            throw GenerationError.referencePoolTooSmall(
                table: key.qualifiedName,
                columns: key.columns,
                poolCount: tuples.count,
                rowCount: rowCount
            )
        }
        self.key = key
        self.tuples = tuples
        self.strategy = strategy
        self.seed = seed
        rng = SplitMix64(seed: seed)
        picker = PoolValuePicker(strategy: strategy, skew: skew, seed: seed)
        picker.bind(count: tuples.count)
    }

    func next() -> [PluginCellValue]? {
        guard let index = picker.nextIndex(count: tuples.count, using: &rng) else { return nil }
        return tuples[index]
    }

    func value(forColumn column: String, in tuple: [PluginCellValue]) -> PluginCellValue? {
        guard let index = key.columns.firstIndex(of: column), index < tuple.count else { return nil }
        return tuple[index]
    }

    func reset() {
        rng = SplitMix64(seed: seed)
        picker.bind(count: tuples.count)
    }
}
