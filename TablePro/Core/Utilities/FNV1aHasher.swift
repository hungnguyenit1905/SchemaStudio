//
//  FNV1aHasher.swift
//  TablePro
//

import Foundation

struct FNV1aHasher {
    private static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01b3

    private(set) var value: UInt64 = FNV1aHasher.offsetBasis

    mutating func combine(byte: UInt8) {
        value ^= UInt64(byte)
        value = value &* Self.prime
    }

    mutating func combine<Bytes: Sequence>(bytes: Bytes) where Bytes.Element == UInt8 {
        for byte in bytes { combine(byte: byte) }
    }

    mutating func combine(_ word: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            combine(byte: UInt8(truncatingIfNeeded: word >> UInt64(shift)))
        }
    }

    mutating func combine(_ flag: Bool) {
        combine(byte: flag ? 1 : 0)
    }

    mutating func combine(_ number: Int64) {
        combine(UInt64(bitPattern: number))
    }

    mutating func combine(_ number: Double) {
        combine((number == 0 ? 0 : number).bitPattern)
    }

    mutating func combine(lengthPrefixed bytes: Data) {
        combine(UInt64(bytes.count))
        combine(bytes: bytes)
    }

    mutating func combine(_ string: String) {
        let utf8 = Array(string.utf8)
        combine(UInt64(utf8.count))
        combine(bytes: utf8)
    }

    static func hash(_ build: (inout FNV1aHasher) -> Void) -> UInt64 {
        var hasher = FNV1aHasher()
        build(&hasher)
        return hasher.value
    }
}
