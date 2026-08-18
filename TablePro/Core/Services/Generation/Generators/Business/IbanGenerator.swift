//
//  IbanGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// One country's IBAN shape from the ISO 13616 registry. `bodyPattern` uses `n`
/// for a digit and `a` for an uppercase letter, which is the registry's own
/// notation, so a new country is transcribed rather than translated.
struct IbanCountryFormat: Sendable, Hashable {
    let country: String
    let bodyPattern: String

    var totalLength: Int { 4 + bodyPattern.count }
}

final class IbanGenerator: ValueGenerator {
    static let identifier = "IBAN"

    static let formats: [IbanCountryFormat] = [
        IbanCountryFormat(country: "DE", bodyPattern: String(repeating: "n", count: 18)),
        IbanCountryFormat(country: "GB", bodyPattern: "aaaa" + String(repeating: "n", count: 14)),
        IbanCountryFormat(country: "FR", bodyPattern: String(repeating: "n", count: 10) + "aa" + String(repeating: "n", count: 11)),
        IbanCountryFormat(country: "NL", bodyPattern: "aaaa" + String(repeating: "n", count: 10)),
        IbanCountryFormat(country: "ES", bodyPattern: String(repeating: "n", count: 20)),
        IbanCountryFormat(country: "IT", bodyPattern: "a" + String(repeating: "n", count: 22))
    ]

    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "country",
            label: "Country",
            type: .choice(
                [ParamChoice(value: "any", label: String(localized: "Any country"))]
                    + formats.map { ParamChoice(value: $0.country) }
            ),
            defaultValue: .string("any")
        )
    ])

    private struct Params: Codable {
        var country: String?
    }

    private static let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    private let candidates: [IbanCountryFormat]
    private let seed: UInt64
    private var rng: SplitMix64

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        let requested = (decoded.country ?? "any").uppercased()
        if requested == "ANY" {
            candidates = Self.formats
        } else {
            guard let match = Self.formats.first(where: { $0.country == requested }) else {
                throw GenerationError.invalidParameters(
                    generator: Self.identifier,
                    reason: "\(requested) is not one of the supported IBAN countries"
                )
            }
            candidates = [match]
        }
        let widest = candidates.map(\.totalLength).max() ?? 34
        try ColumnFit.requireRoom(for: widest, column: column, generator: Self.identifier)
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        let format = candidates[rng.nextInt(upperBound: candidates.count)]
        var body = ""
        for token in format.bodyPattern {
            switch token {
            case "a": body.append(Self.letters[rng.nextInt(upperBound: Self.letters.count)])
            default: body.append(String(rng.nextInt(upperBound: 10)))
            }
        }
        let check = CheckDigits.ibanCheckDigits(country: format.country, body: body)
        return .text(format.country + check + body)
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
