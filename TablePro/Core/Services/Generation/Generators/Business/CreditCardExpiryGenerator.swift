//
//  CreditCardExpiryGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Always in the future, because an expiry date in the past makes every card in
/// the generated table useless to whatever is being tested against it.
final class CreditCardExpiryGenerator: ValueGenerator {
    static let identifier = "CreditCardExpiry"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "yearsAhead",
            label: "Years ahead at most",
            type: .integer(minimum: 1, maximum: 20),
            defaultValue: .int(5)
        ),
        ParamField(
            key: "format",
            label: "Format",
            type: .choice([
                ParamChoice(value: "MM/yy", label: "MM/YY"),
                ParamChoice(value: "MM/yyyy", label: "MM/YYYY")
            ]),
            defaultValue: .string("MM/yy")
        )
    ])

    private struct Params: Codable {
        var yearsAhead: Int?
        var format: String?
    }

    private let monthsAhead: Int
    private let usesFourDigitYear: Bool
    private let reference: DateComponents
    private let seed: UInt64
    private var rng: SplitMix64

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        let years = max(1, decoded.yearsAhead ?? 5)
        monthsAhead = years * 12
        usesFourDigitYear = (decoded.format ?? "MM/yy") == "MM/yyyy"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        reference = calendar.dateComponents([.year, .month], from: Date())
        try ColumnFit.requireRoom(
            for: usesFourDigitYear ? 7 : 5,
            column: column,
            generator: Self.identifier
        )
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        guard let year = reference.year, let month = reference.month else {
            throw GenerationError.invalidParameters(generator: Self.identifier, reason: "the current date is unreadable")
        }
        let offset = rng.nextInt(in: 1...monthsAhead)
        let absolute = (year * 12 + month - 1) + offset
        let expiryYear = absolute / 12
        let expiryMonth = absolute % 12 + 1
        let yearText = usesFourDigitYear
            ? String(format: "%04d", expiryYear)
            : String(format: "%02d", expiryYear % 100)
        return .text(String(format: "%02d", expiryMonth) + "/" + yearText)
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
