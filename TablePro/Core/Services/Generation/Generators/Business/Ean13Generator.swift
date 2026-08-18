//
//  Ean13Generator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

final class Ean13Generator: ValueGenerator {
    static let identifier = "EAN13"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "prefix",
            label: "GS1 prefix",
            type: .text,
            defaultValue: .string(""),
            help: String(localized: "Leading digits shared by every code, such as a country or company prefix.")
        )
    ])

    private struct Params: Codable {
        var prefix: String?
    }

    private let prefix: [Int]
    private let seed: UInt64
    private var rng: SplitMix64

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        let requested = decoded.prefix ?? ""
        let digits = requested.compactMap(\.wholeNumberValue)
        guard digits.count == requested.count, digits.count <= 11 else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "the prefix must be up to 11 digits"
            )
        }
        prefix = digits
        try ColumnFit.requireRoom(for: 13, column: column, generator: Self.identifier)
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        var digits = prefix
        while digits.count < 12 {
            digits.append(rng.nextInt(upperBound: 10))
        }
        digits.append(CheckDigits.gs1Modulo10(appendingTo: digits))
        return .text(digits.map(String.init).joined())
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
