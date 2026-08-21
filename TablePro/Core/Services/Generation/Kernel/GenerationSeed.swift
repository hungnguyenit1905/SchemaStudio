//
//  GenerationSeed.swift
//  TablePro
//

import Foundation

enum GenerationSeed {
    private static let fieldSeparator: UInt8 = 0x00

    static func columnSeed(runSeed: UInt64, table: String, column: String) -> UInt64 {
        FNV1aHasher.hash { hasher in
            hasher.combine(runSeed)
            hasher.combine(table)
            hasher.combine(byte: fieldSeparator)
            hasher.combine(column)
        }
    }

    /// A fresh seed for a run the user has not seeded themselves. This is the one
    /// draw in generation that should not be reproducible: everything downstream is
    /// reproducible *from* it, which is what makes saving it worth anything.
    static func randomSeed() -> UInt64 {
        var system = SystemRandomNumberGenerator()
        return UInt64.random(in: 1 ... UInt64.max, using: &system)
    }

    static func generator(runSeed: UInt64, table: String, column: String) -> SplitMix64 {
        SplitMix64(seed: columnSeed(runSeed: runSeed, table: table, column: column))
    }
}
