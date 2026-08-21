//
//  CreditCardNumberGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum CardNumberFormat: String, Codable, Sendable, CaseIterable {
    case plain
    case grouped
}

final class CreditCardNumberGenerator: ValueGenerator {
    static let identifier = "CreditCardNumber"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "brand",
            label: "Card brand",
            type: .choice(CardBrand.paramChoices),
            defaultValue: .string(CardBrand.any.rawValue)
        ),
        ParamField(
            key: "format",
            label: "Format",
            type: .choice([
                ParamChoice(value: CardNumberFormat.plain.rawValue, label: String(localized: "Digits only")),
                ParamChoice(value: CardNumberFormat.grouped.rawValue, label: String(localized: "Spaced groups"))
            ]),
            defaultValue: .string(CardNumberFormat.plain.rawValue)
        )
    ])

    private struct Params: Codable {
        var brand: CardBrand?
        var format: CardNumberFormat?
    }

    private let brand: CardBrand
    private let format: CardNumberFormat
    private let seed: UInt64
    private var rng: SplitMix64

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        brand = decoded.brand ?? .any
        format = decoded.format ?? .plain
        let widest = CardBrand.issuing.map(\.numberLength).max() ?? 16
        let needed = format == .grouped ? widest + 3 : widest
        try ColumnFit.requireRoom(for: needed, column: column, generator: Self.identifier)
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        let issuer = brand == .any ? CardBrand.issuing[rng.nextInt(upperBound: CardBrand.issuing.count)] : brand
        let prefixes = issuer.prefixes
        let prefix = prefixes[rng.nextInt(upperBound: prefixes.count)]
        var digits = prefix.compactMap(\.wholeNumberValue)
        while digits.count < issuer.numberLength - 1 {
            digits.append(rng.nextInt(upperBound: 10))
        }
        digits.append(CheckDigits.luhn(appendingTo: digits))
        let plain = digits.map(String.init).joined()
        return .text(format == .grouped ? Self.group(plain, brand: issuer) : plain)
    }

    /// American Express prints 4-6-5, every other network prints even groups of
    /// four. Anything else looks wrong to anyone who has held the card.
    private static func group(_ number: String, brand: CardBrand) -> String {
        let sizes = brand == .amex ? [4, 6, 5] : [4, 4, 4, 4]
        var remaining = Substring(number)
        var groups: [String] = []
        for size in sizes {
            guard !remaining.isEmpty else { break }
            groups.append(String(remaining.prefix(size)))
            remaining = remaining.dropFirst(size)
        }
        if !remaining.isEmpty { groups.append(String(remaining)) }
        return groups.joined(separator: " ")
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
