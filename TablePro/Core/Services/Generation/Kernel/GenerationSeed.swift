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

    static func generator(runSeed: UInt64, table: String, column: String) -> SplitMix64 {
        SplitMix64(seed: columnSeed(runSeed: runSeed, table: table, column: column))
    }
}
