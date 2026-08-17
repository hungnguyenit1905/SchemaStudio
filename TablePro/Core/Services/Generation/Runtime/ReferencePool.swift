//
//  ReferencePool.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum ReferencePoolStrategy: String, Codable, Sendable, CaseIterable {
    case random
    case roundRobin
    case oneToOne
    case ensureCoverage
}

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
    let strategy: ReferencePoolStrategy

    private let tuples: [[PluginCellValue]]
    private let seed: UInt64
    private var rng: SplitMix64
    private var position = 0
    private var permutation: [Int] = []

    var count: Int { tuples.count }
    var isEmpty: Bool { tuples.isEmpty }

    init(
        key: ReferenceKey,
        tuples: [[PluginCellValue]],
        strategy: ReferencePoolStrategy = .random,
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
        refillPermutationIfNeeded()
    }

    func next() -> [PluginCellValue]? {
        guard !tuples.isEmpty else { return nil }
        switch strategy {
        case .random:
            return tuples[rng.nextInt(upperBound: tuples.count)]
        case .roundRobin:
            defer { position += 1 }
            return tuples[position % tuples.count]
        case .oneToOne:
            guard position < tuples.count else { return nil }
            defer { position += 1 }
            return tuples[position]
        case .ensureCoverage:
            if position >= permutation.count {
                position = 0
                shufflePermutation()
            }
            defer { position += 1 }
            return tuples[permutation[position]]
        }
    }

    func value(forColumn column: String, in tuple: [PluginCellValue]) -> PluginCellValue? {
        guard let index = key.columns.firstIndex(of: column), index < tuple.count else { return nil }
        return tuple[index]
    }

    func reset() {
        rng = SplitMix64(seed: seed)
        position = 0
        permutation = []
        refillPermutationIfNeeded()
    }

    private func refillPermutationIfNeeded() {
        guard strategy == .ensureCoverage, !tuples.isEmpty else { return }
        permutation = Array(tuples.indices)
        shufflePermutation()
    }

    private func shufflePermutation() {
        guard permutation.count > 1 else { return }
        for index in stride(from: permutation.count - 1, to: 0, by: -1) {
            let target = rng.nextInt(upperBound: index + 1)
            permutation.swapAt(index, target)
        }
    }
}
