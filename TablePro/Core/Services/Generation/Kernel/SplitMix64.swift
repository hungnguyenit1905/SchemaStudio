//
//  SplitMix64.swift
//  TablePro
//

import Foundation

struct SplitMix64: RandomNumberGenerator, Sendable {
    private static let increment: UInt64 = 0x9E37_79B9_7F4A_7C15
    private static let firstMultiplier: UInt64 = 0xBF58_476D_1CE4_E5B9
    private static let secondMultiplier: UInt64 = 0x94D0_49BB_1331_11EB

    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ Self.increment
        var word = state
        word = (word ^ (word >> 30)) &* Self.firstMultiplier
        word = (word ^ (word >> 27)) &* Self.secondMultiplier
        return word ^ (word >> 31)
    }

    /// A span of zero means "the whole 64-bit range" here, because a span is
    /// computed as `upper - lower + 1` and that wraps to zero at full width.
    /// `next(upperBound: 0)` traps, so the caller must come through this.
    mutating func next(span: UInt64) -> UInt64 {
        guard span > 0 else { return next() }
        return next(upperBound: span)
    }

    mutating func nextInt(upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        return Int(next(upperBound: UInt64(upperBound)))
    }

    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        guard range.lowerBound < range.upperBound else { return range.lowerBound }
        let span = range.upperBound - range.lowerBound + 1
        return range.lowerBound + nextInt(upperBound: span)
    }

    mutating func nextUnitFraction() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + nextUnitFraction() * (range.upperBound - range.lowerBound)
    }

    mutating func rollsBelow(percent: Int) -> Bool {
        guard percent > 0 else { return false }
        guard percent < 100 else { return true }
        return nextInt(upperBound: 100) < percent
    }
}
