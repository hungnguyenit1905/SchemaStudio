//
//  CvvGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

final class CvvGenerator: ValueGenerator {
    static let identifier = "CVV"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "brand",
            label: "Card brand",
            type: .choice(CardBrand.paramChoices),
            defaultValue: .string(CardBrand.any.rawValue),
            help: String(localized: "American Express prints four digits, every other network prints three.")
        )
    ])

    private struct Params: Codable {
        var brand: CardBrand?
    }

    private let length: Int
    private let seed: UInt64
    private var rng: SplitMix64

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        length = (decoded.brand ?? .any).securityCodeLength
        try ColumnFit.requireRoom(for: length, column: column, generator: Self.identifier)
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    var distinctValueCount: Int? {
        (0..<length).reduce(1) { total, _ in total * 10 }
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        var code = ""
        for _ in 0..<length {
            code.append(String(rng.nextInt(upperBound: 10)))
        }
        return .text(code)
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
