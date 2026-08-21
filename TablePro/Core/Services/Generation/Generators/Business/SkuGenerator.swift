//
//  SkuGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Pattern-driven stock codes. `A` becomes an uppercase letter, `9` a digit, `*`
/// either; every other character is copied through, so a house format like
/// `TP-AA999-9` is written rather than configured field by field.
final class SkuGenerator: ValueGenerator {
    static let identifier = "SKU"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "pattern",
            label: "Pattern",
            type: .text,
            defaultValue: .string("AAA-9999"),
            help: String(localized: "A is a letter, 9 is a digit, * is either. Anything else is copied as written.")
        )
    ])

    private struct Params: Codable {
        var pattern: String?
    }

    private static let letters = Array("ABCDEFGHIJKLMNPQRSTUVWXYZ")
    private static let digits = Array("0123456789")
    private static let alphanumerics = Array("ABCDEFGHIJKLMNPQRSTUVWXYZ0123456789")

    private let pattern: [Character]
    private let seed: UInt64
    private var rng: SplitMix64

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        let requested = decoded.pattern ?? "AAA-9999"
        guard !requested.isEmpty else {
            throw GenerationError.invalidParameters(generator: Self.identifier, reason: "the pattern is empty")
        }
        pattern = Array(requested)
        try ColumnFit.requireRoom(for: pattern.count, column: column, generator: Self.identifier)
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    var distinctValueCount: Int? {
        var total = 1
        for token in pattern {
            let choices: Int
            switch token {
            case "A": choices = Self.letters.count
            case "9": choices = Self.digits.count
            case "*": choices = Self.alphanumerics.count
            default: continue
            }
            let (product, overflowed) = total.multipliedReportingOverflow(by: choices)
            guard !overflowed else { return Int.max }
            total = product
        }
        return total
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        var value = ""
        value.reserveCapacity(pattern.count)
        for token in pattern {
            switch token {
            case "A": value.append(Self.letters[rng.nextInt(upperBound: Self.letters.count)])
            case "9": value.append(Self.digits[rng.nextInt(upperBound: Self.digits.count)])
            case "*": value.append(Self.alphanumerics[rng.nextInt(upperBound: Self.alphanumerics.count)])
            default: value.append(token)
            }
        }
        return .text(value)
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
