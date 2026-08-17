//
//  ShuffledRangeSource.swift
//  TablePro
//

import Foundation

/// Distinct integers over a finite domain, in a seeded random order, with no
/// retries and no collisions.
///
/// This is the strategy for a unique column whose generator has a closed integer
/// domain: drawing at random and rejecting duplicates costs more and more per row
/// as the domain fills, and near the end it spins. A Fisher-Yates shuffle draws
/// every value exactly once instead.
///
/// The shuffle is lazy. Materializing a ten-million-value domain would cost 80MB
/// even when the run wants a thousand rows, so only the positions that have
/// actually been swapped are stored, and every other position still reads as
/// `lowerBound + position`. Memory is therefore proportional to the rows drawn,
/// not to the domain.
struct ShuffledRangeSource {
    static let maximumDomain: UInt64 = 10_000_000

    private let lowerBound: Int64
    private let domainSize: UInt64
    private let seed: UInt64
    private var swapped: [UInt64: Int64] = [:]
    private var drawn: UInt64 = 0
    private var rng: SplitMix64

    init?(domain: ClosedRange<Int64>, seed: UInt64) {
        let span = UInt64(bitPattern: domain.upperBound &- domain.lowerBound)
        guard span < UInt64.max else { return nil }
        let size = span &+ 1
        guard size <= Self.maximumDomain else { return nil }
        lowerBound = domain.lowerBound
        domainSize = size
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    var remaining: UInt64 { domainSize - drawn }

    mutating func next() -> Int64? {
        guard drawn < domainSize else { return nil }
        let pick = drawn + rng.next(span: domainSize - drawn)
        let picked = element(at: pick)
        if pick != drawn {
            swapped[pick] = element(at: drawn)
        }
        swapped.removeValue(forKey: drawn)
        drawn += 1
        return picked
    }

    mutating func reset() {
        swapped.removeAll(keepingCapacity: true)
        drawn = 0
        rng = SplitMix64(seed: seed)
    }

    private func element(at position: UInt64) -> Int64 {
        swapped[position] ?? lowerBound &+ Int64(bitPattern: position)
    }
}
