//
//  Isbn13Generator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum IsbnFormat: String, Codable, Sendable, CaseIterable {
    case plain
    case hyphenated
}

final class Isbn13Generator: ValueGenerator {
    static let identifier = "ISBN13"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "format",
            label: "Format",
            type: .choice([
                ParamChoice(value: IsbnFormat.plain.rawValue, label: String(localized: "Digits only")),
                ParamChoice(value: IsbnFormat.hyphenated.rawValue, label: String(localized: "Hyphenated"))
            ]),
            defaultValue: .string(IsbnFormat.plain.rawValue)
        )
    ])

    private struct Params: Codable {
        var format: IsbnFormat?
    }

    private static let booklandPrefixes = ["978", "979"]

    private let format: IsbnFormat
    private let seed: UInt64
    private var rng: SplitMix64

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        format = decoded.format ?? .plain
        try ColumnFit.requireRoom(
            for: format == .hyphenated ? 17 : 13,
            column: column,
            generator: Self.identifier
        )
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        let bookland = Self.booklandPrefixes[rng.nextInt(upperBound: Self.booklandPrefixes.count)]
        var digits = bookland.compactMap(\.wholeNumberValue)
        while digits.count < 12 {
            digits.append(rng.nextInt(upperBound: 10))
        }
        digits.append(CheckDigits.gs1Modulo10(appendingTo: digits))
        let plain = digits.map(String.init).joined()
        guard format == .hyphenated else { return .text(plain) }
        return .text(Self.hyphenate(plain))
    }

    /// Registration-group boundaries vary by agency, so this splits on the one
    /// shape that is always correct for a generated number: prefix, single-digit
    /// group, publisher, title, check digit.
    private static func hyphenate(_ digits: String) -> String {
        let scalars = Array(digits)
        guard scalars.count == 13 else { return digits }
        let parts = [
            String(scalars[0..<3]),
            String(scalars[3..<4]),
            String(scalars[4..<8]),
            String(scalars[8..<12]),
            String(scalars[12..<13])
        ]
        return parts.joined(separator: "-")
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
