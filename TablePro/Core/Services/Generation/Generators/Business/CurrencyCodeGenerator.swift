//
//  CurrencyCodeGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// ISO 4217. A closed, short vocabulary, so it lives in code rather than costing
/// a dataset file.
final class CurrencyCodeGenerator: ValueGenerator {
    static let identifier = "CurrencyCode"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "codes",
            label: "Codes",
            type: .stringList,
            defaultValue: .array([]),
            help: String(localized: "Leave empty to draw from the widely traded currencies.")
        ),
        ParamField(
            key: "form",
            label: "Form",
            type: .choice([
                ParamChoice(value: "alphabetic", label: String(localized: "Letters, such as USD")),
                ParamChoice(value: "numeric", label: String(localized: "Numbers, such as 840"))
            ]),
            defaultValue: .string("alphabetic")
        )
    ])

    private struct Params: Codable {
        var codes: [String]?
        var form: String?
    }

    private static let widelyTraded: [(alphabetic: String, numeric: String)] = [
        ("USD", "840"), ("EUR", "978"), ("JPY", "392"), ("GBP", "826"), ("AUD", "036"),
        ("CAD", "124"), ("CHF", "756"), ("CNY", "156"), ("HKD", "344"), ("SGD", "702"),
        ("VND", "704"), ("KRW", "410"), ("THB", "764"), ("INR", "356"), ("SEK", "752")
    ]

    private let codes: [String]
    private let seed: UInt64
    private var rng: SplitMix64

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        let requested = decoded.codes ?? []
        if requested.isEmpty {
            let numeric = (decoded.form ?? "alphabetic") == "numeric"
            codes = Self.widelyTraded.map { numeric ? $0.numeric : $0.alphabetic }
        } else {
            codes = requested
        }
        guard !codes.isEmpty else {
            throw GenerationError.invalidParameters(generator: Self.identifier, reason: "the code list is empty")
        }
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    var distinctValueCount: Int? { Set(codes).count }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        .text(codes[rng.nextInt(upperBound: codes.count)])
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
